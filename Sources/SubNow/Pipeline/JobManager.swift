import Foundation

/// 任务调度：每视频一个任务，分阶段渐进增强。
/// 阶段：提取音频 → 转录(草稿) → 挂原文 → 翻译(草稿) → 双语粗稿挂载 → [精做：重转录+强翻译 → 热替换]
/// 健壮性：转录/翻译各 40 分钟、提取 10 分钟超时；超时与用户取消共用 CancelToken，
/// whisper/ffmpeg 在后台线程读取该标记，因此超时能真正中止而不是干等。
/// 取消不留死账（清记账，下次播放可重新询问）。
@MainActor
final class JobManager {
    static let shared = JobManager()

    enum Stage: String {
        case queued = "排队中"
        case paused = "已暂停"
        case audio = "提取音频"
        case transcribe = "转录"
        case mountOriginal = "写入原文"
        case translate = "翻译"
        case compose = "生成双语"
        case finalTranscribe = "精做转录"
        case finalTranslate = "精做翻译"
        case finalCompose = "生成精做版"
        case done = "完成"
        case failed = "失败"
        case cancelled = "已取消"
    }

    /// 跨线程取消标记：用户取消、抢占让位与阶段超时都写这里；whisper/ffmpeg 回调在后台线程只读。
    final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var timedOut = false
        private var preempted = false
        private var cancelledByUser = false

        func cancel(timedOut: Bool = false) {
            lock.lock()
            cancelled = true
            if timedOut { self.timedOut = true }
            lock.unlock()
        }

        /// 用户取消 / 退出清理：优先于抢占判定（正在让位的任务也应直接取消）
        func cancelByUser() {
            lock.lock()
            cancelled = true
            cancelledByUser = true
            lock.unlock()
        }

        /// 暂停让位：和取消共用中止信号，但稍后可以换新 token 续跑
        func preempt() {
            lock.lock()
            cancelled = true
            preempted = true
            lock.unlock()
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
        var didPreempt: Bool { lock.lock(); defer { lock.unlock() }; return preempted }
        var wasCancelledByUser: Bool { lock.lock(); defer { lock.unlock() }; return cancelledByUser }
    }

    /// 已完成的阶段产物。暂停续跑时据此跳过音频/转录，只补没做完的部分。
    struct Transcript: Codable {
        let language: String
        var segments: [Segment]
    }

    struct Job {
        let videoPath: String
        let key: String
        var stage: Stage = .queued
        var pct: Double = 0
        var detail = ""
        var task: Task<Void, Never>?
        var token = CancelToken()
        var workDir: URL?
        var audioReady = false
        var draft: Transcript?
        var draftReady = false
        var final: Transcript?
        var originalNotified = false
        var draftNotified = false
        var finalNotified = false

        init(videoPath: String, key: String? = nil) {
            self.videoPath = videoPath
            self.key = key ?? JobKeys.path(videoPath)
        }
    }

    struct MenuJob {
        let title: String
        let videoPath: String
        let active: Bool
        let paused: Bool
        let failed: Bool
        let pct: Double
    }

    private(set) var jobs: [Job] = []   // 新任务在前
    private var runningCount = 0
    var onJobsChanged: (() -> Void)?

    /// 未完成任务快照：按路径 hash 去重，跨重启/崩溃保留。
    private var persisted: [String: PersistedJob] = [:]
    private let persistQueue = DispatchQueue(label: "com.y10n.subnow.jobs.persist", qos: .utility)

    // 播放器 OSD 进度：同一视频最多每 10 秒发一条，避免遮挡播放器自己的 OSD；阶段切换强制发。
    private var osdLast: [String: (text: String, at: Date)] = [:]
    private var audioLast: [String: (fraction: Double?, seconds: TimeInterval)] = [:]
    private var audioPaused: [String: Bool] = [:]
    private let osdInterval: TimeInterval = 10

    private init() {
        persisted = JobPersistence.load()
        WorkspaceMigrator.migrateIfNeeded()
        hydratePersistedJobs()
        cleanupOrphanWorkDirs()
    }

    // MARK: - 对外

    /// 入队即最高优先级：正在跑的其他任务会让位（暂停、保留进度）。
    /// preempt=false 用于批量恢复历史任务，避免互相抢占空转。
    func enqueue(videoPath: String, preempt: Bool = true) {
        // 重启后尚未载入内存的持久化任务：先按 hash 找回来，再走正常的提权逻辑
        hydratePersistedIfNeeded(videoPath)
        let key = JobKeys.path(videoPath)
        if let idx = jobs.firstIndex(where: { $0.key == key }),
           !Self.isTerminal(jobs[idx].stage) || jobs[idx].stage == .failed {
            // 用户再次点名这个视频：提到队首；暂停/失败的直接转为待续跑，复用检查点
            let job = jobs.remove(at: idx)
            jobs.insert(job, at: 0)
            let retrying = jobs[0].stage == .failed
            if jobs[0].stage == .paused || retrying {
                jobs[0].stage = .queued
                jobs[0].detail = retrying ? "重试上次进度" : "继续上次进度"
                jobs[0].task = nil
                jobs[0].pct = max(jobs[0].pct, 0)
            }
            persist(videoPath)
            if preempt { preemptRunning(except: videoPath) }
            pump()
            onJobsChanged?()
            return
        }
        jobs.removeAll { $0.key == key }
        jobs.insert(Job(videoPath: videoPath), at: 0)
        trimHistory()
        persist(videoPath)
        if preempt { preemptRunning(except: videoPath) }
        pump()
        onJobsChanged?()
        Log.info("任务入队：\(videoPath)")
    }

    /// 手动续跑一个暂停/失败任务（正常会在新任务结束后自动续跑）
    func resume(videoPath: String) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == videoPath }),
              jobs[idx].stage == .paused || jobs[idx].stage == .failed else { return }
        let job = jobs.remove(at: idx)
        jobs.insert(job, at: 0)
        let retrying = jobs[0].stage == .failed
        jobs[0].stage = .queued
        jobs[0].detail = retrying ? "重试上次进度" : "继续上次进度"
        jobs[0].task = nil
        persist(videoPath)
        preemptRunning(except: videoPath)
        pump()
        onJobsChanged?()
        Log.info("\(retrying ? "重试" : "继续")任务：\(videoPath)")
    }

    func cancel(videoPath: String) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == videoPath }) else { return }
        jobs[idx].token.cancelByUser()
        jobs[idx].task?.cancel()
        // 没在跑的任务不会走 execute 的清理，这里直接落取消态并删掉工作目录
        if jobs[idx].task == nil,
           [.queued, .paused, .failed].contains(jobs[idx].stage) {
            let key = jobs[idx].key
            jobs[idx].stage = .cancelled
            jobs[idx].detail = "用户取消"
            if let dir = jobs[idx].workDir,
               !HistoryStore.load().contains(where: { $0.key == key }) {
                try? FileManager.default.removeItem(at: dir)
                jobs[idx].workDir = nil
            }
            jobs[idx].audioReady = false
            jobs[idx].draft = nil
            jobs[idx].draftReady = false
            jobs[idx].final = nil
            persisted.removeValue(forKey: key)
            savePersisted()
            Task { await PlayerBook.shared.forget(pathPrefix: videoPath) }
            pump()
        }
        onJobsChanged?()
    }

    /// 退出时等待运行中任务收尾，并把可恢复进度落盘。
    /// 注意：退出不是用户取消——工作目录必须保留，下次启动可继续。
    func shutdown(timeout: TimeInterval = 5) async {
        for idx in jobs.indices where !Self.isTerminal(jobs[idx].stage) {
            jobs[idx].token.preempt()
            jobs[idx].task?.cancel()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while runningCount > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if runningCount > 0 {
            Log.warn("退出时仍有 \(runningCount) 个任务未收尾，按已落盘检查点恢复")
        }
        for idx in jobs.indices where !Self.isTerminal(jobs[idx].stage) {
            if jobs[idx].stage != .paused {
                jobs[idx].stage = .paused
                jobs[idx].detail = "退出时暂停"
            }
            persist(jobs[idx].videoPath)
        }
        flushPersistence()
    }

    static func isTerminal(_ stage: Stage) -> Bool {
        [.done, .failed, .cancelled].contains(stage)
    }

    /// 任意未结束任务（含排队/暂停），菜单状态行用
    var activeJob: Job? {
        jobs.first { !Self.isTerminal($0.stage) }
    }

    /// 真正在跑的任务（不含排队/暂停），进度角标用
    var runningJob: Job? {
        jobs.first { !Self.isTerminal($0.stage) && $0.stage != .queued && $0.stage != .paused }
    }

    var menuJobs: [MenuJob] {
        jobs.prefix(6).map { job in
            let name = URL(fileURLWithPath: job.videoPath).lastPathComponent
            let title: String
            switch job.stage {
            case .paused:
                title = "已暂停 \(Int(job.pct))% · \(name)"
            case .failed:
                title = "失败 · \(name)"
            default:
                title = "\(job.stage.rawValue) \(Int(job.pct))% · \(name)"
            }
            return MenuJob(title: title, videoPath: job.videoPath,
                           active: !Self.isTerminal(job.stage),
                           paused: job.stage == .paused,
                           failed: job.stage == .failed,
                           pct: job.pct)
        }
    }

    // MARK: - 队列泵

    private func pump() {
        let maxConcurrent = max(1, Config.shared.maxConcurrent)
        while runningCount < maxConcurrent {
            let idx: Int
            if let queued = jobs.firstIndex(where: { $0.stage == .queued && $0.task == nil }) {
                idx = queued
            } else if let paused = jobs.firstIndex(where: { $0.stage == .paused && $0.task == nil }) {
                // 新任务都跑完了，接着续跑暂停的
                jobs[paused].stage = .queued
                jobs[paused].detail = "继续上次进度"
                idx = paused
            } else {
                break
            }
            let path = jobs[idx].videoPath
            // 暂停时旧 token 已置取消，续跑必须换新 token
            jobs[idx].token = CancelToken()
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.execute(videoPath: path)
            }
            jobs[idx].task = task
            runningCount += 1
        }
    }

    /// 新视频优先：并发位不够时，让进度最少的运行任务暂停。
    private func preemptRunning(except videoPath: String) {
        let maxConcurrent = max(1, Config.shared.maxConcurrent)
        guard runningCount >= maxConcurrent else { return }
        let victims = jobs.indices
            .filter {
                jobs[$0].videoPath != videoPath &&
                jobs[$0].task != nil &&
                !Self.isTerminal(jobs[$0].stage) &&
                jobs[$0].stage != .paused &&
                !jobs[$0].token.didPreempt
            }
            .sorted { jobs[$0].pct < jobs[$1].pct }
        let needed = max(1, runningCount - maxConcurrent + 1)
        for idx in victims.prefix(needed) {
            let path = jobs[idx].videoPath
            jobs[idx].token.preempt()
            jobs[idx].task?.cancel()
            Log.info("任务暂停让位（\(Int(jobs[idx].pct))%）：\(path) ← \(videoPath)")
        }
    }

    /// 历史只留最近 20 条已结束任务，长期运行不无限累积。
    /// 失败任务保留检查点等用户重试或取消，不参与这里的淘汰。
    private func trimHistory() {
        let finished = jobs.filter { $0.stage == .done || $0.stage == .cancelled }
        guard finished.count > 20 else { return }
        for job in finished.suffix(finished.count - 20) {
            jobs.removeAll { $0.videoPath == job.videoPath }
        }
    }

    private func updateJob(_ path: String, mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == path }) else { return }
        mutate(&jobs[idx])
        if Self.isTerminal(jobs[idx].stage) {
            osdLast.removeValue(forKey: path)
            audioLast.removeValue(forKey: path)
            audioPaused.removeValue(forKey: path)
        }
        onJobsChanged?()
    }

    // MARK: - 持久化（路径 hash 去重 + 检查点）

    /// 该视频是否已有未结束任务（含暂停/失败）。AppDelegate 用它过滤旧的恢复提示。
    func hasActiveJob(videoPath: String) -> Bool {
        let key = JobKeys.path(videoPath)
        return jobs.contains { $0.key == key && !Self.isTerminal($0.stage) }
    }

    private func hydratePersistedJobs() {
        var loaded: [Job] = []
        let records = persisted.values.sorted { $0.updatedAt > $1.updatedAt }
        for rec in records {
            guard let stage = Stage(rawValue: rec.stage) else {
                persisted.removeValue(forKey: rec.key)
                continue
            }
            // 完成/取消的记录不该留在表里；顺手清理
            if stage == .done || stage == .cancelled {
                persisted.removeValue(forKey: rec.key)
                continue
            }
            // 网络盘未挂载时保留记录，不判死刑；等用户再次入队时再校验
            guard FileManager.default.fileExists(atPath: rec.videoPath) else {
                Log.info("未完成任务所在文件暂不可用，保留记录：\(rec.videoPath)")
                continue
            }
            if let fp = rec.fingerprint, let now = FileFingerprint.read(rec.videoPath), fp != now {
                discardPersisted(key: rec.key, reason: "视频文件已变化")
                continue
            }
            if let job = makeJob(from: rec) {
                loaded.append(job)
            }
        }
        jobs = loaded
        if !loaded.isEmpty {
            let failed = loaded.filter { $0.stage == .failed }.count
            Log.info("载入 \(loaded.count) 个未完成任务（\(failed) 个待重试）")
        }
    }

    /// 入队/恢复时按路径 hash 找回持久化进度
    private func hydratePersistedIfNeeded(_ videoPath: String) {
        let key = JobKeys.path(videoPath)
        guard !jobs.contains(where: { $0.key == key }), let rec = persisted[key] else { return }
        guard FileManager.default.fileExists(atPath: rec.videoPath) else { return }
        if let fp = rec.fingerprint, let now = FileFingerprint.read(rec.videoPath), fp != now {
            discardPersisted(key: key, reason: "视频文件已变化")
            return
        }
        guard let job = makeJob(from: rec) else { return }
        jobs.insert(job, at: 0)
        Log.info("按路径 hash 复用上次进度：\(videoPath)")
    }

    private func makeJob(from rec: PersistedJob) -> Job? {
        guard let stage = Stage(rawValue: rec.stage),
              stage != .done, stage != .cancelled else { return nil }
        var job = Job(videoPath: rec.videoPath, key: rec.key)
        job.stage = stage == .failed ? .failed : .paused
        job.pct = rec.pct
        job.detail = stage == .failed ? "上次失败：\(rec.detail)" : "上次中断 · \(stage.rawValue)"
        if let raw = rec.workDir {
            let dir = URL(fileURLWithPath: raw)
            if FileManager.default.fileExists(atPath: dir.path) { job.workDir = dir }
        }
        if let dir = job.workDir {
            job.audioReady = rec.audioReady
                && FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio.wav").path)
        }
        job.draft = rec.draft
        job.draftReady = rec.draftReady
        job.final = rec.final
        job.originalNotified = rec.originalNotified
        job.draftNotified = rec.draftNotified
        job.finalNotified = rec.finalNotified
        return job
    }

    private func persist(_ videoPath: String) {
        guard let job = jobs.first(where: { $0.videoPath == videoPath }) else { return }
        if job.stage == .done || job.stage == .cancelled {
            persisted.removeValue(forKey: job.key)
            savePersisted()
            return
        }
        // 文件暂时不可达时保留旧指纹，避免网络盘抖动导致进度被误判作废
        let fingerprint = FileFingerprint.read(job.videoPath) ?? persisted[job.key]?.fingerprint
        persisted[job.key] = PersistedJob(
            videoPath: job.videoPath,
            key: job.key,
            fingerprint: fingerprint,
            stage: job.stage.rawValue,
            pct: job.pct,
            detail: job.detail,
            workDir: job.workDir?.path,
            audioReady: job.audioReady,
            draft: job.draft,
            draftReady: job.draftReady,
            final: job.final,
            originalNotified: job.originalNotified,
            draftNotified: job.draftNotified,
            finalNotified: job.finalNotified,
            updatedAt: Date()
        )
        prunePersistedIfNeeded()
        savePersisted()
    }

    private func prunePersistedIfNeeded() {
        guard persisted.count > 50 else { return }
        let activeKeys = Set(jobs.filter { !Self.isTerminal($0.stage) }.map(\.key))
        for (key, rec) in persisted.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }) {
            guard persisted.count > 50 else { break }
            guard !activeKeys.contains(key) else { continue }
            persisted.removeValue(forKey: key)
            if let dir = rec.workDir, !HistoryStore.load().contains(where: { $0.key == key }) {
                try? FileManager.default.removeItem(atPath: dir)
            }
        }
    }

    private func savePersisted() {
        let snapshot = persisted
        persistQueue.async { JobPersistence.write(snapshot) }
    }

    private func flushPersistence() {
        let snapshot = persisted
        persistQueue.sync { JobPersistence.write(snapshot) }
    }

    private func discardPersisted(key: String, reason: String) {
        guard let rec = persisted.removeValue(forKey: key) else { return }
        if let dir = rec.workDir, !HistoryStore.load().contains(where: { $0.key == key }) {
            try? FileManager.default.removeItem(atPath: dir)
        }
        savePersisted()
        Log.warn("丢弃旧进度（\(reason)）：\(rec.videoPath)")
    }

    /// 清掉没有任何持久化记录/历史记录引用的 job-* 目录（崩溃/旧版本遗留）。
    private func cleanupOrphanWorkDirs() {
        let fm = FileManager.default
        var referenced = Set(persisted.values.compactMap { $0.workDir }.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        })
        for rec in HistoryStore.load() {
            referenced.insert(URL(fileURLWithPath: rec.workDir).standardizedFileURL.path)
        }
        var removed = 0
        var bytes: Int64 = 0
        for root in [Paths.tmpDir, Paths.workspaceDir] {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in entries where url.lastPathComponent.hasPrefix("job-") {
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                guard isDir else { continue }
                if referenced.contains(url.standardizedFileURL.path) { continue }
                bytes += Workspace.size(of: url)
                if (try? fm.removeItem(at: url)) != nil { removed += 1 }
            }
        }
        if removed > 0 {
            Log.info("清理孤儿工作目录 \(removed) 个，释放 \(bytes / 1_048_576) MB")
        }
    }

    // MARK: - 执行

    private func execute(videoPath: String) async {
        guard let job = jobs.first(where: { $0.videoPath == videoPath }) else { return }
        // 续跑/重试时清掉上一轮的暂停标记，避免 OSD 显示“已暂停”而实际在跑
        audioPaused.removeValue(forKey: videoPath)
        audioLast.removeValue(forKey: videoPath)
        osdLast.removeValue(forKey: videoPath)
        let token = job.token
        let video = URL(fileURLWithPath: videoPath)
        let stem = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        let workDir: URL
        if let cached = job.workDir, FileManager.default.fileExists(atPath: cached.path) {
            workDir = cached
        } else {
            // 路径 hash 固定工作目录：同一视频始终落到同一目录，重启/重试不漂移
            do {
                let created = try Workspace.create(for: job.key)
                updateJob(videoPath) { $0.workDir = created }
                persist(videoPath)
                workDir = created
            } catch {
                Log.error("工作目录创建失败：\(error.localizedDescription)")
                updateJob(videoPath) {
                    $0.stage = .failed
                    $0.detail = "工作目录创建失败"
                    $0.task = nil
                }
                runningCount -= 1
                pump()
                return
            }
        }
        let book = PlayerBook.shared

        do {
            defer {
                if let stage = jobs.first(where: { $0.videoPath == videoPath })?.stage {
                    if stage == .done {
                        // 完成的工作区作为历史档案保留：音频、transcript 与全部成品都在这里
                        persisted.removeValue(forKey: job.key)
                        savePersisted()
                        updateJob(videoPath) {
                            $0.workDir = nil
                            $0.audioReady = false
                            $0.draft = nil
                            $0.draftReady = false
                            $0.final = nil
                            $0.task = nil
                        }
                    } else if stage == .cancelled {
                        if !HistoryStore.load().contains(where: { $0.key == job.key }) {
                            try? FileManager.default.removeItem(at: workDir)
                        }
                        persisted.removeValue(forKey: job.key)
                        savePersisted()
                        updateJob(videoPath) {
                            $0.workDir = nil
                            $0.audioReady = false
                            $0.draft = nil
                            $0.draftReady = false
                            $0.final = nil
                            $0.task = nil
                        }
                    } else {
                        // 暂停 / 失败：保留音频、转录与逐行译文，等待继续或重试
                        persist(videoPath)
                        updateJob(videoPath) { $0.task = nil }
                    }
                }
                runningCount -= 1
                pump()
            }

            try Task.checkCancellation()
            if token.isCancelled { throw CancellationError() }

            let cfg = Config.shared
            let customSocket = cfg.customSocketPath
            guard let ffmpeg = FFmpegLocator.locate() else {
                throw JobError("缺 ffmpeg，请到组件就绪检查安装")
            }

            await book.set("processing", for: video, sidecar: VideoProbe.sidecarExists(for: video).exists)

            // ① 提取音频（10 分钟超时；暂停续跑时复用已完成的 wav）
            let wav = workDir.appendingPathComponent("audio.wav")
            let audioReady = jobs.first(where: { $0.videoPath == videoPath })?.audioReady == true
                && FileManager.default.fileExists(atPath: wav.path)
            if !audioReady {
                // ffprobe 只读文件头；先拿时长，提取进度才能换算成百分比。
                // 超时/失败不阻塞主流程，OSD 退化为“已提取 mm:ss”。
                let totalDuration = await Task.detached(priority: .utility) {
                    VideoProbe.durationSeconds(of: video, ffprobeURL: FFmpegLocator.locateFFprobe())
                }.value
                try await setStage(videoPath, .audio, pct: 2, detail: "ffmpeg 提取 16kHz 音频", token: token)
                reportOSD("提取音频中 · 播放时会自动暂停，暂停视频可加速",
                          videoPath: videoPath, force: true)
                let pauseStats = PauseStats()
                let volumePath = PlaybackGate.volumePath(of: video.path)
                try await withTimeout(seconds: 600, label: "音频提取", token: token,
                                      paused: { pauseStats.pausedSeconds }) {
                    try await AudioExtractor.extract(
                        video: video, to: wav, ffmpeg: ffmpeg,
                        volumePath: volumePath,
                        totalDuration: totalDuration,
                        isCancelled: { token.isCancelled },
                        stats: pauseStats,
                        onProgress: { fraction, seconds in
                            Task { @MainActor in
                                self.handleAudioProgress(videoPath, fraction: fraction, seconds: seconds)
                            }
                        },
                        onPauseChanged: { paused in
                            Task { @MainActor in
                                self.handleAudioPause(videoPath, paused: paused)
                            }
                        })
                }
                updateJob(videoPath) { $0.audioReady = true }
                persist(videoPath)
            }

            // ② 草稿转录（40 分钟超时；暂停续跑时复用已完成的转录）
            let segmentsURL = workDir.appendingPathComponent("segments.json")
            var draft: Transcript
            if let cached = jobs.first(where: { $0.videoPath == videoPath })?.draft {
                draft = cached
            } else {
                try await setStage(videoPath, .transcribe, pct: 5, detail: "whisper 转录（\(cfg.draftModelFile)）", token: token)
                reportOSD("转录中 · 完成后自动挂原文", videoPath: videoPath, force: true)
                let draftResult = try await withTimeout(seconds: 2400, label: "转录", token: token) {
                    try await Self.transcribeWithModel(modelURL: cfg.draftModelURL, vadURL: cfg.vadModelURL,
                                                       wav: wav, language: cfg.language, token: token,
                                                       main: self, videoPath: videoPath,
                                                       progressBase: 5, progressSpan: 50)
                }
                var draftLanguage = draftResult.language
                if draftLanguage == "auto" || draftLanguage.isEmpty { draftLanguage = "orig" }
                draftLanguage = normalizeLanguage(draftLanguage)
                draft = Transcript(language: draftLanguage,
                                   segments: Segments.splitLong(draftResult.segments, language: draftLanguage,
                                                                lineLen: cfg.lineLen))
                updateJob(videoPath) { $0.draft = draft }
                persist(videoPath)
            }

            let language = draft.language
            let draftCompleted = jobs.first(where: { $0.videoPath == videoPath })?.draftReady == true

            // 暂停在精做阶段：粗稿已完整落盘并挂载过，直接跳回精做。
            // 否则重跑粗稿翻译会用粗稿内容覆盖 segments.json 里的精做进度。
            if !draftCompleted {
                // 按行复用已落盘的译文（历史复跑、或本次暂停前翻译到一半），配合批回调做增量落盘
                if let prior = Writers.readSegmentsFile(from: segmentsURL),
                   prior.language == draft.language, prior.segments.count == draft.segments.count {
                    for i in draft.segments.indices where prior.segments[i].src == draft.segments[i].src {
                        draft.segments[i].zh = prior.segments[i].zh
                    }
                }
                updateJob(videoPath) { $0.draft = draft }
                try Writers.writeSegmentsFile(draft.segments, language: language, to: segmentsURL)
                var segments = draft.segments

                // ③ 原文即挂载（最快可用：转录完马上能看）
                try await setStage(videoPath, .mountOriginal, pct: 55, detail: "写入原文字幕", token: token)
                let srtOriginal = Workspace.outputURL(for: .originalSrt, key: job.key, stem: stem, language: language)
                try Writers.writeSrt(segments, language: language, to: srtOriginal, mode: .original)
                if cfg.exportKinds.contains(.originalSrt) {
                    try? Workspace.export([.originalSrt], key: job.key, stem: stem,
                                          language: language, to: dir)
                }
                if await Self.mountInBackground(subFile: srtOriginal, videoPath: videoPath,
                                                title: MpvIPC.originalTrackTitle, customSocketPath: customSocket),
                   jobs.first(where: { $0.videoPath == videoPath })?.originalNotified == false {
                    await Self.notifyInBackground("原文转录已生成，正在翻译…",
                                                  videoPath: videoPath, customSocketPath: customSocket)
                    updateJob(videoPath) { $0.originalNotified = true }
                }

                // ④ 草稿翻译（40 分钟超时）
                var zhSegments = segments
                if cfg.translationKind != .none {
                    try await setStage(videoPath, .translate, pct: 58, detail: "翻译（草稿）", token: token)
                    reportOSD("翻译中 · 完成后替换为双语", videoPath: videoPath, force: true)
                    let translator = Translator.make()
                    let translations = try await withTimeout(seconds: 2400, label: "翻译", token: token) {
                        try await translator.translate(
                            segments: segments, language: language, lineLen: cfg.lineLen,
                            onBatch: { done, total, partial in
                                var merged = segments
                                for i in merged.indices { merged[i].zh = partial[i] ?? merged[i].zh }
                                try? Writers.writeSegmentsFile(merged, language: language, to: segmentsURL)
                                Task { @MainActor in
                                    self.updateTranslateProgress(videoPath, done: done, total: total,
                                                                 base: 58, span: 30, prefix: "翻译（草稿）")
                                }
                            },
                            isCancelled: { token.isCancelled })
                    }
                    for i in zhSegments.indices {
                        zhSegments[i].zh = translations[i] ?? segments[i].src
                    }
                } else {
                    for i in zhSegments.indices { zhSegments[i].zh = zhSegments[i].src }
                }

                // ⑤ 双语粗稿落盘 + 挂载
                try await setStage(videoPath, .compose, pct: 90, detail: "写双语 ASS", token: token)
                reportOSD("正在生成双语字幕…", videoPath: videoPath, force: true)
                try writeAllOutputs(zhSegments, language: language, workDir: workDir,
                                    key: job.key, stem: stem, videoDir: dir)
                await book.set("draft-done", for: video, sidecar: true)
                updateJob(videoPath) { $0.draftReady = true }
                persist(videoPath)

                let assFile = Workspace.outputURL(for: .zhTopAss, key: job.key, stem: stem, language: language)
                if await Self.mountInBackground(subFile: assFile, videoPath: videoPath,
                                                title: MpvIPC.draftTrackTitle, customSocketPath: customSocket) {
                    await Self.removeInBackground(title: MpvIPC.originalTrackTitle, videoPath: videoPath,
                                                  customSocketPath: customSocket)
                    if jobs.first(where: { $0.videoPath == videoPath })?.draftNotified == false {
                        await Self.notifyInBackground("粗稿字幕已生成，正在精做…",
                                                      videoPath: videoPath, customSocketPath: customSocket)
                        updateJob(videoPath) { $0.draftNotified = true }
                    }
                }
            }

            // ⑥ 精做（可选；缺失或关闭则到粗稿为止）
            if cfg.autoFinal && ComponentCenter.shared.isFinalReady {
                try await runFinalPhase(videoPath: videoPath, wav: wav, language: language,
                                        dir: dir, stem: stem, workDir: workDir, key: job.key,
                                        book: book, token: token, customSocketPath: customSocket)
            } else {
                await book.set("done", for: video, sidecar: true)
                try await setStage(videoPath, .done, pct: 100,
                                   detail: cfg.autoFinal ? "完成（精做模型未就绪，已到粗稿）" : "完成", token: token)
                Notify.shared.postDone(videoPath: videoPath, stage: "粗稿版")
            }

            recordHistory(videoPath: videoPath, key: job.key, stem: stem,
                          videoDir: dir, workDir: workDir, fallbackLanguage: language)
            Notify.shared.clearOffers(for: videoPath)
            Log.info("任务完成：\(videoPath)")

        } catch is CancellationError {
            if token.didTimeOut {
                await book.set("failed", for: video, sidecar: false)
                updateJob(videoPath) {
                    $0.stage = .failed
                    $0.detail = "超时中止"
                    $0.task = nil
                }
                persist(videoPath)
                Log.error("任务超时：\(videoPath)")
            } else if token.didPreempt && !token.wasCancelledByUser {
                // 让位给新视频：保留工作目录与已落盘译文，等新任务结束后自动续跑
                updateJob(videoPath) {
                    $0.stage = .paused
                    $0.detail = "已暂停，稍后自动继续"
                    $0.task = nil
                }
                persist(videoPath)
                Log.info("任务暂停让位：\(videoPath)")
            } else {
                await book.forget(pathPrefix: videoPath)  // 取消可重触发
                persisted.removeValue(forKey: job.key)
                savePersisted()
                updateJob(videoPath) {
                    $0.stage = .cancelled
                    $0.detail = "用户取消"
                    $0.task = nil
                }
                Log.info("任务取消：\(videoPath)")
            }
        } catch {
            await book.set("failed", for: video, sidecar: false)
            // 保留工作目录与已完成的音频/转录：失败后从检查点重试，不再从 SMB 重读整部片子
            updateJob(videoPath) {
                $0.stage = .failed
                $0.detail = error.localizedDescription
                $0.task = nil
            }
            persist(videoPath)
            Log.error("任务失败：\(videoPath) — \(error.localizedDescription)")
        }
    }

    /// 精做：large-v3 重转录（复用 wav）+ 强翻译 → 整体热替换粗稿
    private func runFinalPhase(videoPath: String, wav: URL, language: String,
                               dir: URL, stem: String, workDir: URL, key: String, book: PlayerBook,
                               token: CancelToken, customSocketPath: String) async throws {
        let cfg = Config.shared
        var final: Transcript
        if let cached = jobs.first(where: { $0.videoPath == videoPath })?.final {
            final = cached
        } else {
            try await setStage(videoPath, .finalTranscribe, pct: 90, detail: "精做转录（\(cfg.finalModelFile)）", token: token)
            reportOSD("精做转录中 · 粗稿可继续观看", videoPath: videoPath, force: true)
            let finalResult = try await withTimeout(seconds: 2400, label: "精做转录", token: token) {
                try await Self.transcribeWithModel(modelURL: cfg.finalModelURL, vadURL: cfg.vadModelURL,
                                                   wav: wav, language: cfg.language, token: token,
                                                   main: self, videoPath: videoPath,
                                                   progressBase: 90, progressSpan: 5)
            }
            var finalLanguage = language
            if finalResult.language != "auto" && !finalResult.language.isEmpty {
                finalLanguage = normalizeLanguage(finalResult.language)
            }
            final = Transcript(language: finalLanguage,
                               segments: Segments.splitLong(finalResult.segments, language: finalLanguage,
                                                            lineLen: cfg.lineLen))
            updateJob(videoPath) { $0.final = final }
            persist(videoPath)
        }

        let segmentsURL = workDir.appendingPathComponent("segments.json")
        if let prior = Writers.readSegmentsFile(from: segmentsURL),
           prior.language == final.language, prior.segments.count == final.segments.count {
            for i in final.segments.indices where prior.segments[i].src == final.segments[i].src {
                final.segments[i].zh = prior.segments[i].zh
            }
        }
        updateJob(videoPath) { $0.final = final }
        persist(videoPath)
        try Writers.writeSegmentsFile(final.segments, language: final.language, to: segmentsURL)

        let outputLanguage = final.language
        var segments = final.segments
        var zhSegments = segments
        if cfg.translationKind != .none {
            try await setStage(videoPath, .finalTranslate, pct: 95, detail: "精做翻译（强模型）", token: token)
            reportOSD("精做翻译中 · 粗稿可继续观看", videoPath: videoPath, force: true)
            let translator = Translator.makeFinal()
            let translations = try await withTimeout(seconds: 2400, label: "精做翻译", token: token) {
                try await translator.translate(
                    segments: segments, language: outputLanguage, lineLen: cfg.lineLen,
                    onBatch: { done, total, partial in
                        var merged = segments
                        for i in merged.indices { merged[i].zh = partial[i] ?? merged[i].zh }
                        try? Writers.writeSegmentsFile(merged, language: outputLanguage, to: segmentsURL)
                        Task { @MainActor in
                            self.updateTranslateProgress(videoPath, done: done, total: total,
                                                         base: 95, span: 3, prefix: "精做翻译")
                        }
                    },
                    isCancelled: { token.isCancelled })
            }
            for i in zhSegments.indices {
                zhSegments[i].zh = translations[i] ?? segments[i].src
            }
        } else {
            for i in zhSegments.indices { zhSegments[i].zh = zhSegments[i].src }
        }

        try await setStage(videoPath, .finalCompose, pct: 98, detail: "生成精做版", token: token)
        reportOSD("正在生成精做版…", videoPath: videoPath, force: true)
        try writeAllOutputs(zhSegments, language: outputLanguage, workDir: workDir,
                            key: key, stem: stem, videoDir: dir)

        let assFile = Workspace.outputURL(for: .zhTopAss, key: key, stem: stem, language: outputLanguage)
        if await Self.mountInBackground(subFile: assFile, videoPath: videoPath,
                                        title: MpvIPC.finalTrackTitle, customSocketPath: customSocketPath) {
            await Self.removeInBackground(title: MpvIPC.draftTrackTitle, videoPath: videoPath,
                                          customSocketPath: customSocketPath)
            await Self.removeInBackground(title: MpvIPC.originalTrackTitle, videoPath: videoPath,
                                          customSocketPath: customSocketPath)
            if jobs.first(where: { $0.videoPath == videoPath })?.finalNotified == false {
                await Self.notifyInBackground("精做版字幕已生成", videoPath: videoPath,
                                              customSocketPath: customSocketPath)
                updateJob(videoPath) { $0.finalNotified = true }
            }
        }

        await book.set("done", for: videoURL(videoPath), sidecar: true)
        try await setStage(videoPath, .done, pct: 100, detail: "精做完成", token: token)
        Notify.shared.postDone(videoPath: videoPath, stage: "精做版")
    }

    private func videoURL(_ p: String) -> URL { URL(fileURLWithPath: p) }

    /// 四份成品与 segments.json 一律先写入工作区；视频目录只复制用户勾选的成品。
    private func writeAllOutputs(_ segments: [Segment], language: String,
                                 workDir: URL, key: String, stem: String, videoDir: URL) throws {
        try Writers.writeBilingualAss(
            segments, language: language,
            to: Workspace.outputURL(for: .zhTopAss, key: key, stem: stem, language: language), zhFirst: true)
        try Writers.writeBilingualAss(
            segments, language: language,
            to: Workspace.outputURL(for: .zhBottomAss, key: key, stem: stem, language: language), zhFirst: false)
        try Writers.writeSrt(
            segments, language: language,
            to: Workspace.outputURL(for: .chineseSrt, key: key, stem: stem, language: language), mode: .chinese)
        // 精做会换一套转录，原文 SRT 也要跟着更新，避免与最终 ASS 内容不一致
        try Writers.writeSrt(
            segments, language: language,
            to: Workspace.outputURL(for: .originalSrt, key: key, stem: stem, language: language), mode: .original)
        try Writers.writeSegmentsFile(segments, language: language,
                                      to: workDir.appendingPathComponent("segments.json"))

        do {
            let exported = try Workspace.export(Config.shared.exportKinds, key: key, stem: stem,
                                                language: language, to: videoDir, pruneOthers: true)
            Log.info("已导出成品到视频目录：\(exported.map(\.label).joined(separator: "、"))")
        } catch {
            // NAS 掉线等情况下成品仍在工作区，历史窗口可重新导出
            Log.warn("导出成品到视频目录失败：\(error.localizedDescription)")
        }
    }

    private func recordHistory(videoPath: String, key: String, stem: String,
                               videoDir: URL, workDir: URL, fallbackLanguage: String) {
        guard let job = jobs.first(where: { $0.videoPath == videoPath }) else { return }
        let transcript = job.final ?? job.draft
        let language = transcript?.language ?? fallbackLanguage
        let exported = Config.shared.exportKinds.filter {
            FileManager.default.fileExists(
                atPath: videoDir.appendingPathComponent($0.fileName(stem: stem, language: language)).path)
        }
        let record = HistoryRecord(key: key, videoPath: videoPath, title: stem,
                                   language: language, finishedAt: Date(),
                                   segmentCount: transcript?.segments.count ?? 0,
                                   status: "已完成", workDir: workDir.path,
                                   exported: exported.map(\.rawValue))
        HistoryStore.upsert(record)
        NotificationCenter.default.post(name: .subNowHistoryChanged, object: nil)
        Log.info("历史记录已归档：\(stem)（\(record.segmentCount) 条）")
    }

    // MARK: - 后台执行（模型加载 / 转录 / 挂载都不在主线程）

    nonisolated private static func mountInBackground(subFile: URL, videoPath: String,
                                                      title: String, customSocketPath: String) async -> Bool {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: Mounter.mount(subFile: subFile, toVideo: videoPath,
                                                     title: title, customSocketPath: customSocketPath))
            }
        }
    }

    nonisolated private static func removeInBackground(title: String, videoPath: String,
                                                       customSocketPath: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Mounter.remove(title: title, fromVideo: videoPath, customSocketPath: customSocketPath)
                cont.resume()
            }
        }
    }

    nonisolated private static func notifyInBackground(_ text: String, videoPath: String,
                                                       customSocketPath: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                Mounter.notify(text, forVideo: videoPath, customSocketPath: customSocketPath)
                cont.resume()
            }
        }
    }

    /// 加载 → 转录 → 在同一个后台队列里释放。
    /// 权重常驻 1.6–3 GB；若把引擎留在 execute 作用域，翻译和精做阶段会叠加峰值内存。
    nonisolated private static func transcribeWithModel(
        modelURL: URL, vadURL: URL?, wav: URL, language: String, token: CancelToken,
        main: JobManager, videoPath: String, progressBase: Double, progressSpan: Double
    ) async throws -> (segments: [Segment], language: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(segments: [Segment], language: String), Error>) in
            // whisper 是长时间后台计算：utility 让系统在播放/前台应用繁忙时优先让路
            DispatchQueue.global(qos: .utility).async {
                let result = Result<(segments: [Segment], language: String), Error> {
                    let engine = try WhisperEngine(modelURL: modelURL, vadURL: vadURL)
                    let output = try engine.run(wavURL: wav, language: language,
                                                progress: { pct in
                                                    Task { @MainActor in
                                                        main.updateTranscribeProgress(videoPath, pct: pct,
                                                                                      base: progressBase, span: progressSpan)
                                                    }
                                                },
                                                isCancelled: { token.isCancelled })
                    return output
                }
                cont.resume(with: result)
            }
        }
    }

    // MARK: - 超时

    struct JobError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    /// 超时会置位 token，让不合作的后台任务（whisper/ffmpeg）自己停下来；
    /// 同时 cancelAll 取消 op Task，避免作用域退出时无限等待。
    /// paused：返回已因播放让路而暂停的秒数，这部分不计入超时。
    private func withTimeout<T: Sendable>(seconds: TimeInterval, label: String, token: CancelToken,
                                          paused: (@Sendable () -> TimeInterval)? = nil,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                if let paused {
                    let started = Date()
                    while true {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        if Date().timeIntervalSince(started) - paused() >= seconds {
                            token.cancel(timedOut: true)
                            throw JobError("\(label)超时（\(Int(seconds / 60)) 分钟）")
                        }
                    }
                }
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                token.cancel(timedOut: true)
                throw JobError("\(label)超时（\(Int(seconds / 60)) 分钟）")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            if token.didTimeOut {
                throw JobError("\(label)超时（\(Int(seconds / 60)) 分钟）")
            }
            return result
        }
    }

    // MARK: - 辅助

    /// 语言码收敛（空/auto → orig）
    private func normalizeLanguage(_ lang: String) -> String {
        let l = lang.lowercased()
        return (l.isEmpty || l == "auto") ? "orig" : l
    }

    private func setStage(_ path: String, _ stage: Stage, pct: Double, detail: String,
                          token: CancelToken) async throws {
        try Task.checkCancellation()
        if token.isCancelled { throw CancellationError() }
        updateJob(path) {
            $0.stage = stage
            $0.pct = pct
            $0.detail = detail
        }
        persist(path)
    }

    private func updateTranscribeProgress(_ path: String, pct: Int, base: Double, span: Double) {
        let isFinal = base >= 90
        let label = isFinal ? "精做转录" : "转录"
        updateJob(path) {
            $0.pct = base + Double(pct) / 100 * span
            $0.detail = "\(label) \(pct)%"
        }
        reportOSD(isFinal ? "\(label) \(pct)% · 粗稿可继续观看"
                          : "\(label) \(pct)% · 完成后自动挂原文",
                  videoPath: path)
    }

    private func updateTranslateProgress(_ path: String, done: Int, total: Int, base: Double, span: Double, prefix: String) {
        let isFinal = base >= 90
        updateJob(path) {
            $0.pct = base + span * Double(done) / Double(max(total, 1))
            $0.detail = "\(prefix) \(done)/\(total) 批"
        }
        let label = isFinal ? "精做翻译" : "翻译"
        reportOSD(isFinal ? "\(label) \(done)/\(total) 批 · 粗稿可继续观看"
                          : "\(label) \(done)/\(total) 批",
                  videoPath: path)
    }

    // MARK: - 播放器 OSD 进度

    private func handleAudioProgress(_ path: String, fraction: Double?, seconds: TimeInterval) {
        audioLast[path] = (fraction, seconds)
        let paused = audioPaused[path] == true
        if let fraction {
            updateJob(path) {
                $0.pct = 2 + fraction * 3
                $0.detail = "提取音频 \(Int(fraction * 100))%"
            }
            if paused {
                reportOSD("播放中，提取已暂停 · 暂停视频可加速", videoPath: path)
            } else {
                reportOSD("提取音频 \(Int(fraction * 100))% · 可继续播放（会自动让路）",
                          videoPath: path)
            }
        } else {
            let text = Self.clockText(seconds)
            updateJob(path) { $0.detail = "提取音频 \(text)" }
            reportOSD(paused ? "播放中，提取已暂停 · 暂停视频可加速"
                             : "提取音频中 · 已提取 \(text) · 可继续播放",
                      videoPath: path)
        }
    }

    private func handleAudioPause(_ path: String, paused: Bool) {
        audioPaused[path] = paused
        let suffix = audioLast[path]?.fraction.map { " \(Int($0 * 100))%" } ?? ""
        reportOSD(paused ? "播放中，提取已暂停 · 暂停视频可加速"
                         : "提取继续\(suffix)",
                  videoPath: path, force: true)
    }

    /// OSD 每 5 秒最多一条，避免转录/翻译回调刷屏；force 用于阶段切换与暂停/恢复。
    private func reportOSD(_ text: String, videoPath: String, force: Bool = false) {
        let now = Date()
        if !force, let last = osdLast[videoPath], now.timeIntervalSince(last.at) < osdInterval {
            return
        }
        osdLast[videoPath] = (text, now)
        let socket = Config.shared.customSocketPath
        Task { await Self.notifyInBackground(text, videoPath: videoPath, customSocketPath: socket) }
    }

    private static func clockText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
