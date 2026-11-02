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

    /// 跨线程取消标记：用户取消与阶段超时都写这里；whisper/ffmpeg 回调在后台线程只读。
    final class CancelToken: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        private var timedOut = false

        func cancel(timedOut: Bool = false) {
            lock.lock()
            cancelled = true
            if timedOut { self.timedOut = true }
            lock.unlock()
        }

        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
        var didTimeOut: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    }

    struct Job {
        let videoPath: String
        var stage: Stage = .queued
        var pct: Double = 0
        var detail = ""
        var task: Task<Void, Never>?
        let token = CancelToken()
    }

    struct MenuJob {
        let title: String
        let videoPath: String
        let active: Bool
        let pct: Double
    }

    private(set) var jobs: [Job] = []   // 新任务在前
    private var runningCount = 0
    var onJobsChanged: (() -> Void)?

    private init() {}

    // MARK: - 对外

    func enqueue(videoPath: String) {
        if let existing = jobs.first(where: { $0.videoPath == videoPath }),
           !Self.isTerminal(existing.stage) {
            return
        }
        jobs.removeAll { $0.videoPath == videoPath }
        jobs.insert(Job(videoPath: videoPath), at: 0)
        trimHistory()
        pump()
        onJobsChanged?()
        Log.info("任务入队：\(videoPath)")
    }

    func cancel(videoPath: String) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == videoPath }) else { return }
        jobs[idx].token.cancel()
        jobs[idx].task?.cancel()
        // 还没开始跑的直接落取消态，避免占着队列等 pump 才发现
        if jobs[idx].stage == .queued && jobs[idx].task == nil {
            jobs[idx].stage = .cancelled
            jobs[idx].detail = "用户取消"
        }
        onJobsChanged?()
    }

    func cancelAll() {
        for idx in jobs.indices where !Self.isTerminal(jobs[idx].stage) {
            jobs[idx].token.cancel()
            jobs[idx].task?.cancel()
        }
        onJobsChanged?()
    }

    /// 退出时等待运行中任务收尾（whisper 中止、ffmpeg 退出码落账）
    func shutdown(timeout: TimeInterval = 5) async {
        cancelAll()
        let deadline = Date().addingTimeInterval(timeout)
        while runningCount > 0 && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if runningCount > 0 {
            Log.warn("退出时仍有 \(runningCount) 个任务未收尾")
        }
    }

    var menuJobs: [MenuJob] {
        jobs.prefix(6).map { job in
            MenuJob(title: "\(job.stage.rawValue) \(Int(job.pct))% · \(URL(fileURLWithPath: job.videoPath).lastPathComponent)",
                    videoPath: job.videoPath,
                    active: !Self.isTerminal(job.stage),
                    pct: job.pct)
        }
    }

    // MARK: - 队列泵

    private func pump() {
        let maxConcurrent = max(1, Config.shared.maxConcurrent)
        while runningCount < maxConcurrent,
              let idx = jobs.firstIndex(where: { $0.stage == .queued && $0.task == nil }) {
            let path = jobs[idx].videoPath
            let task: Task<Void, Never> = Task { [weak self] in
                await self?.execute(videoPath: path)
            }
            jobs[idx].task = task
            runningCount += 1
        }
    }

    private static func isTerminal(_ stage: Stage) -> Bool {
        [.done, .failed, .cancelled].contains(stage)
    }

    /// 历史只留最近 20 条已结束任务，长期运行不无限累积
    private func trimHistory() {
        let finished = jobs.filter { Self.isTerminal($0.stage) }
        guard finished.count > 20 else { return }
        for job in finished.suffix(finished.count - 20) {
            jobs.removeAll { $0.videoPath == job.videoPath }
        }
    }

    private func updateJob(_ path: String, mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == path }) else { return }
        mutate(&jobs[idx])
        onJobsChanged?()
    }

    // MARK: - 执行

    private func execute(videoPath: String) async {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == videoPath }) else { return }
        let token = jobs[idx].token
        let video = URL(fileURLWithPath: videoPath)
        let stem = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        let workDir = Paths.tmpDir.appendingPathComponent("job-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let book = PlayerBook.shared

        do {
            defer {
                try? FileManager.default.removeItem(at: workDir)
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

            // ① 提取音频（10 分钟超时）
            try await setStage(videoPath, .audio, pct: 2, detail: "ffmpeg 提取 16kHz 音频", token: token)
            let wav = workDir.appendingPathComponent("audio.wav")
            try await withTimeout(seconds: 600, label: "音频提取", token: token) {
                try await AudioExtractor.extract(video: video, to: wav, ffmpeg: ffmpeg,
                                                 isCancelled: { token.isCancelled })
            }

            // ② 草稿转录（40 分钟超时）
            try await setStage(videoPath, .transcribe, pct: 5, detail: "whisper 转录（\(cfg.draftModelFile)）", token: token)
            let draftEngine = try await Self.loadEngine(modelURL: cfg.draftModelURL, vadURL: cfg.vadModelURL)
            let draftResult = try await withTimeout(seconds: 2400, label: "转录", token: token) {
                try await Self.transcribeOnBackground(engine: draftEngine, wav: wav, language: cfg.language,
                                                      token: token, main: self, videoPath: videoPath,
                                                      progressBase: 5, progressSpan: 50)
            }
            var language = draftResult.language
            if language == "auto" || language.isEmpty { language = "orig" }
            language = normalizeLanguage(language)

            var segments = Segments.splitLong(draftResult.segments, language: language, lineLen: cfg.lineLen)
            let segmentsURL = dir.appendingPathComponent("\(stem).segments.json")
            // 复跑时按行复用上次译文（src 完全一致才复用），配合翻译批回调做增量落盘
            if let prior = Writers.readSegmentsFile(from: segmentsURL),
               prior.language == language, prior.segments.count == segments.count {
                for i in segments.indices where prior.segments[i].src == segments[i].src {
                    segments[i].zh = prior.segments[i].zh
                }
            }
            try Writers.writeSegmentsFile(segments, language: language, to: segmentsURL)

            // ③ 原文即挂载（最快可用：转录完马上能看）
            try await setStage(videoPath, .mountOriginal, pct: 55, detail: "写入原文字幕", token: token)
            let srtOriginal = dir.appendingPathComponent(Writers.originalSrtName(stem: stem, language: language))
            try Writers.writeSrt(segments, language: language, to: srtOriginal, mode: .original)
            if await Self.mountInBackground(subFile: srtOriginal, videoPath: videoPath,
                                            title: MpvIPC.originalTrackTitle, customSocketPath: customSocket) {
                await Self.notifyInBackground("📝 原文转录已生成，正在翻译…",
                                              videoPath: videoPath, customSocketPath: customSocket)
            }

            // ④ 草稿翻译（40 分钟超时）
            var zhSegments = segments
            if cfg.translationKind != .none {
                try await setStage(videoPath, .translate, pct: 58, detail: "翻译（草稿）", token: token)
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
            try writeAllOutputs(zhSegments, language: language, dir: dir, stem: stem)
            await book.set("draft-done", for: video, sidecar: true)

            let assFile = dir.appendingPathComponent("\(stem).ass")
            if await Self.mountInBackground(subFile: assFile, videoPath: videoPath,
                                            title: MpvIPC.draftTrackTitle, customSocketPath: customSocket) {
                await Self.removeInBackground(title: MpvIPC.originalTrackTitle, videoPath: videoPath,
                                              customSocketPath: customSocket)
                await Self.notifyInBackground("📝 粗稿字幕已生成，正在精做…",
                                              videoPath: videoPath, customSocketPath: customSocket)
            }

            // ⑥ 精做（可选；缺失或关闭则到粗稿为止）
            if cfg.autoFinal && ComponentCenter.shared.isFinalReady {
                try await runFinalPhase(videoPath: videoPath, wav: wav, language: language,
                                        dir: dir, stem: stem, book: book,
                                        token: token, customSocketPath: customSocket)
            } else {
                await book.set("done", for: video, sidecar: true)
                try await setStage(videoPath, .done, pct: 100,
                                   detail: cfg.autoFinal ? "完成（精做模型未就绪，已到粗稿）" : "完成", token: token)
                Notify.shared.postDone(videoPath: videoPath, stage: "粗稿版")
            }

            Notify.shared.clearOffers(for: videoPath)
            Log.info("任务完成：\(videoPath)")

        } catch is CancellationError {
            if token.didTimeOut {
                await book.set("failed", for: video, sidecar: false)
                updateJob(videoPath) {
                    $0.stage = .failed
                    $0.detail = "超时中止"
                }
                Log.error("任务超时：\(videoPath)")
            } else {
                await book.forget(pathPrefix: videoPath)  // 取消可重触发
                updateJob(videoPath) {
                    $0.stage = .cancelled
                    $0.detail = "用户取消"
                }
                Log.info("任务取消：\(videoPath)")
            }
        } catch {
            await book.set("failed", for: video, sidecar: false)
            updateJob(videoPath) {
                $0.stage = .failed
                $0.detail = error.localizedDescription
            }
            Log.error("任务失败：\(videoPath) — \(error.localizedDescription)")
        }
    }

    /// 精做：large-v3 重转录（复用 wav）+ 强翻译 → 整体热替换粗稿
    private func runFinalPhase(videoPath: String, wav: URL, language: String,
                               dir: URL, stem: String, book: PlayerBook,
                               token: CancelToken, customSocketPath: String) async throws {
        let cfg = Config.shared
        try await setStage(videoPath, .finalTranscribe, pct: 90, detail: "精做转录（\(cfg.finalModelFile)）", token: token)
        let engine = try await Self.loadEngine(modelURL: cfg.finalModelURL, vadURL: cfg.vadModelURL)
        let finalResult = try await withTimeout(seconds: 2400, label: "精做转录", token: token) {
            try await Self.transcribeOnBackground(engine: engine, wav: wav, language: cfg.language,
                                                  token: token, main: self, videoPath: videoPath,
                                                  progressBase: 90, progressSpan: 5)
        }
        var language = language
        if finalResult.language != "auto" && !finalResult.language.isEmpty {
            language = normalizeLanguage(finalResult.language)
        }

        var segments = Segments.splitLong(finalResult.segments, language: language, lineLen: cfg.lineLen)
        let segmentsURL = dir.appendingPathComponent("\(stem).segments.json")
        if let prior = Writers.readSegmentsFile(from: segmentsURL),
           prior.language == language, prior.segments.count == segments.count {
            for i in segments.indices where prior.segments[i].src == segments[i].src {
                segments[i].zh = prior.segments[i].zh
            }
        }
        try Writers.writeSegmentsFile(segments, language: language, to: segmentsURL)

        var zhSegments = segments
        if cfg.translationKind != .none {
            try await setStage(videoPath, .finalTranslate, pct: 95, detail: "精做翻译（强模型）", token: token)
            let translator = Translator.makeFinal()
            let translations = try await withTimeout(seconds: 2400, label: "精做翻译", token: token) {
                try await translator.translate(
                    segments: segments, language: language, lineLen: cfg.lineLen,
                    onBatch: { done, total, partial in
                        var merged = segments
                        for i in merged.indices { merged[i].zh = partial[i] ?? merged[i].zh }
                        try? Writers.writeSegmentsFile(merged, language: language, to: segmentsURL)
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
        try writeAllOutputs(zhSegments, language: language, dir: dir, stem: stem)

        let assFile = dir.appendingPathComponent("\(stem).ass")
        if await Self.mountInBackground(subFile: assFile, videoPath: videoPath,
                                        title: MpvIPC.finalTrackTitle, customSocketPath: customSocketPath) {
            await Self.removeInBackground(title: MpvIPC.draftTrackTitle, videoPath: videoPath,
                                          customSocketPath: customSocketPath)
            await Self.removeInBackground(title: MpvIPC.originalTrackTitle, videoPath: videoPath,
                                          customSocketPath: customSocketPath)
            await Self.notifyInBackground("✅ 精做版字幕已生成", videoPath: videoPath,
                                          customSocketPath: customSocketPath)
        }

        await book.set("done", for: videoURL(videoPath), sidecar: true)
        try await setStage(videoPath, .done, pct: 100, detail: "精做完成", token: token)
        Notify.shared.postDone(videoPath: videoPath, stage: "精做版")
    }

    private func videoURL(_ p: String) -> URL { URL(fileURLWithPath: p) }

    private func writeAllOutputs(_ segments: [Segment], language: String, dir: URL, stem: String) throws {
        try Writers.writeBilingualAss(segments, language: language,
                                      to: dir.appendingPathComponent("\(stem).ass"), zhFirst: true)
        try Writers.writeBilingualAss(segments, language: language,
                                      to: dir.appendingPathComponent("\(stem).zh-bottom.ass"), zhFirst: false)
        try Writers.writeSrt(segments, language: language,
                             to: dir.appendingPathComponent("\(stem).zh.srt"), mode: .chinese)
        try Writers.writeSegmentsFile(segments, language: language,
                                      to: dir.appendingPathComponent("\(stem).segments.json"))
    }

    // MARK: - 后台执行（模型加载 / 转录 / 挂载都不在主线程）

    nonisolated private static func loadEngine(modelURL: URL, vadURL: URL?) async throws -> WhisperEngine {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { cont.resume(returning: try WhisperEngine(modelURL: modelURL, vadURL: vadURL)) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

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

    nonisolated private static func transcribeOnBackground(
        engine: WhisperEngine, wav: URL, language: String, token: CancelToken,
        main: JobManager, videoPath: String, progressBase: Double, progressSpan: Double
    ) async throws -> (segments: [Segment], language: String) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(segments: [Segment], language: String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result<(segments: [Segment], language: String), Error> {
                    try engine.run(wavURL: wav, language: language,
                                   progress: { pct in
                                       Task { @MainActor in
                                           main.updateTranscribeProgress(videoPath, pct: pct,
                                                                         base: progressBase, span: progressSpan)
                                       }
                                   },
                                   isCancelled: { token.isCancelled })
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
    private func withTimeout<T: Sendable>(seconds: TimeInterval, label: String, token: CancelToken,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
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
    }

    private func updateTranscribeProgress(_ path: String, pct: Int, base: Double, span: Double) {
        updateJob(path) {
            $0.pct = base + Double(pct) / 100 * span
            $0.detail = "转录 \(pct)%"
        }
    }

    private func updateTranslateProgress(_ path: String, done: Int, total: Int, base: Double, span: Double, prefix: String) {
        updateJob(path) {
            $0.pct = base + span * Double(done) / Double(max(total, 1))
            $0.detail = "\(prefix) \(done)/\(total) 批"
        }
    }
}
