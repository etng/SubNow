import Foundation

/// 任务调度：每视频一个任务，分阶段渐进增强。
/// 阶段：提取音频 → 转录(草稿) → 挂原文 → 翻译(草稿) → 双语粗稿挂载 → [精做：重转录+强翻译 → 热替换]
/// 健壮性：转录/翻译各 40 分钟、提取 10 分钟超时强杀；任务可取消；崩溃恢复靠 PlayerBook；
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

    struct Job {
        let videoPath: String
        var stage: Stage = .queued
        var pct: Double = 0
        var detail = ""
        var task: Task<Void, Never>?
    }

    private(set) var jobs: [Job] = []   // 新任务在前
    private var runningCount = 0
    var onJobsChanged: (() -> Void)?

    /// 跨线程取消标记（whisper 回调在后台线程读）
    private final class CancelBox: @unchecked Sendable {
        private let lock = NSLock()
        private var set: Set<String> = []
        func add(_ p: String) { lock.lock(); set.insert(p); lock.unlock() }
        func remove(_ p: String) { lock.lock(); set.remove(p); lock.unlock() }
        func contains(_ p: String) -> Bool { lock.lock(); defer { lock.unlock() }; return set.contains(p) }
    }
    private let cancelBox = CancelBox()

    private init() {}

    // MARK: - 对外

    func enqueue(videoPath: String) {
        if let existing = jobs.first(where: { $0.videoPath == videoPath }),
           ![Stage.done, .failed, .cancelled].contains(existing.stage) {
            return
        }
        jobs.removeAll { $0.videoPath == videoPath }
        jobs.insert(Job(videoPath: videoPath), at: 0)
        pump()
        onJobsChanged?()
        Log.info("任务入队：\(videoPath)")
    }

    func cancel(videoPath: String) {
        cancelBox.add(videoPath)
        if let idx = jobs.firstIndex(where: { $0.videoPath == videoPath }) {
            jobs[idx].task?.cancel()
        }
    }

    func cancelAll() {
        for job in jobs {
            cancelBox.add(job.videoPath)
            job.task?.cancel()
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

    private func updateJob(_ path: String, mutate: (inout Job) -> Void) {
        guard let idx = jobs.firstIndex(where: { $0.videoPath == path }) else { return }
        mutate(&jobs[idx])
        onJobsChanged?()
    }

    // MARK: - 执行

    private func execute(videoPath: String) async {
        let video = URL(fileURLWithPath: videoPath)
        let stem = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        let workDir = Paths.tmpDir.appendingPathComponent("job-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let book = PlayerBook.shared

        do {
            defer {
                cancelBox.remove(videoPath)
                try? FileManager.default.removeItem(at: workDir)
                runningCount -= 1
                pump()
            }

            let cfg = Config.shared
            guard let ffmpeg = FFmpegLocator.locate() else {
                throw JobError("缺 ffmpeg，请到组件就绪检查安装")
            }

            await book.set("processing", for: video, sidecar: VideoProbe.sidecarExists(for: video).exists)

            // ① 提取音频（10 分钟超时）
            try await setStage(videoPath, .audio, pct: 2, detail: "ffmpeg 提取 16kHz 音频")
            let wav = workDir.appendingPathComponent("audio.wav")
            try await withTimeout(seconds: 600, label: "音频提取") {
                try await AudioExtractor.extract(video: video, to: wav, ffmpeg: ffmpeg,
                                                 isCancelled: { self.isCancelled(videoPath) })
            }

            // ② 草稿转录（40 分钟超时）
            try await setStage(videoPath, .transcribe, pct: 5, detail: "whisper 转录（\(cfg.draftModelFile)）")
            let draftEngine = try WhisperEngine(modelURL: cfg.draftModelURL, vadURL: cfg.vadModelURL)
            let draftResult = try await withTimeout(seconds: 2400, label: "转录") {
                try await Self.transcribeOnBackground(engine: draftEngine, wav: wav,
                                                      language: cfg.language,
                                                      videoPath: videoPath, self_: self)
            }
            var language = draftResult.language
            if language == "auto" || language.isEmpty { language = "orig" }
            language = normalizeLanguage(language)
            let segments = Segments.splitLong(draftResult.segments, language: language, lineLen: cfg.lineLen)

            // ③ 原文即挂载（最快可用：转录完马上能看）
            try await setStage(videoPath, .mountOriginal, pct: 55, detail: "写入原文字幕")
            let srtOriginal = dir.appendingPathComponent("\(stem).\(language).srt")
            try Writers.writeSrt(segments, language: language, to: srtOriginal, mode: .original)
            if Mounter.mount(subFile: srtOriginal, toVideo: videoPath, title: MpvIPC.originalTrackTitle) {
                Mounter.notify("📝 原文转录已生成，正在翻译…", forVideo: videoPath)
            }

            // ④ 草稿翻译（40 分钟超时）
            var zhSegments = segments
            if cfg.translationKind != .none {
                try await setStage(videoPath, .translate, pct: 58, detail: "翻译（草稿）")
                let translator = Translator.make()
                let translations = try await withTimeout(seconds: 2400, label: "翻译") {
                    try await translator.translate(
                        segments: segments, language: language, lineLen: cfg.lineLen,
                        onBatch: { done, total in
                            Task { @MainActor in
                                self.updateTranslateProgress(videoPath, done: done, total: total,
                                                             base: 58, span: 30, prefix: "翻译（草稿）")
                            }
                        },
                        isCancelled: { self.isCancelled(videoPath) })
                }
                for i in zhSegments.indices {
                    zhSegments[i].zh = translations[i] ?? segments[i].src
                }
            } else {
                for i in zhSegments.indices { zhSegments[i].zh = zhSegments[i].src }
            }

            // ⑤ 双语粗稿落盘 + 挂载
            try await setStage(videoPath, .compose, pct: 90, detail: "写双语 ASS")
            try writeAllOutputs(zhSegments, language: language, dir: dir, stem: stem)
            await book.set("draft-done", for: video, sidecar: true)

            let assFile = dir.appendingPathComponent("\(stem).ass")
            if Mounter.mount(subFile: assFile, toVideo: videoPath, title: MpvIPC.draftTrackTitle) {
                Mounter.remove(title: MpvIPC.originalTrackTitle, fromVideo: videoPath)
                Mounter.notify("📝 粗稿字幕已生成，正在精做…", forVideo: videoPath)
            }

            // ⑥ 精做（可选；缺失或关闭则到粗稿为止）
            if cfg.autoFinal && ComponentCenter.shared.isFinalReady {
                try await runFinalPhase(videoPath: videoPath, wav: wav, language: language,
                                        dir: dir, stem: stem, book: book)
            } else {
                await book.set("done", for: video, sidecar: true)
                try await setStage(videoPath, .done, pct: 100,
                                   detail: cfg.autoFinal ? "完成（精做模型未就绪，已到粗稿）" : "完成")
                Notify.shared.postDone(videoPath: videoPath, stage: "粗稿版")
            }

            Notify.shared.clearOffers(for: videoPath)
            Log.info("任务完成：\(videoPath)")

        } catch is CancellationError {
            await book.forget(pathPrefix: videoPath)  // 取消可重触发
            updateJob(videoPath) {
                $0.stage = .cancelled
                $0.detail = "用户取消"
            }
            Log.info("任务取消：\(videoPath)")
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
                               dir: URL, stem: String, book: PlayerBook) async throws {
        let cfg = Config.shared
        try await setStage(videoPath, .finalTranscribe, pct: 62, detail: "精做转录（\(cfg.finalModelFile)）")
        let engine = try WhisperEngine(modelURL: cfg.finalModelURL, vadURL: cfg.vadModelURL)
        let finalResult = try await withTimeout(seconds: 2400, label: "精做转录") {
            try await Self.transcribeOnBackground(engine: engine, wav: wav,
                                                  language: cfg.language,
                                                  videoPath: videoPath, self_: self)
        }
        var language = language
        if finalResult.language != "auto" && !finalResult.language.isEmpty {
            language = normalizeLanguage(finalResult.language)
        }
        let segments = Segments.splitLong(finalResult.segments, language: language, lineLen: cfg.lineLen)

        var zhSegments = segments
        if cfg.translationKind != .none {
            try await setStage(videoPath, .finalTranslate, pct: 68, detail: "精做翻译（强模型）")
            let translator = Translator.makeFinal()
            let translations = try await withTimeout(seconds: 2400, label: "精做翻译") {
                try await translator.translate(
                    segments: segments, language: language, lineLen: cfg.lineLen,
                    onBatch: { done, total in
                        Task { @MainActor in
                            self.updateTranslateProgress(videoPath, done: done, total: total,
                                                         base: 68, span: 25, prefix: "精做翻译")
                        }
                    },
                    isCancelled: { self.isCancelled(videoPath) })
            }
            for i in zhSegments.indices {
                zhSegments[i].zh = translations[i] ?? segments[i].src
            }
        } else {
            for i in zhSegments.indices { zhSegments[i].zh = zhSegments[i].src }
        }

        try await setStage(videoPath, .finalCompose, pct: 95, detail: "生成精做版")
        try writeAllOutputs(zhSegments, language: language, dir: dir, stem: stem)

        let assFile = dir.appendingPathComponent("\(stem).ass")
        if Mounter.mount(subFile: assFile, toVideo: videoPath, title: MpvIPC.finalTrackTitle) {
            Mounter.remove(title: MpvIPC.draftTrackTitle, fromVideo: videoPath)
            Mounter.remove(title: MpvIPC.originalTrackTitle, fromVideo: videoPath)
            Mounter.notify("✅ 精做版字幕已生成", forVideo: videoPath)
        }

        await book.set("done", for: videoURL(videoPath), sidecar: true)
        try await setStage(videoPath, .done, pct: 100, detail: "精做完成")
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

    // MARK: - 转录（GCD 线程执行，避免阻塞协作线程池；进度/取消回调桥回主线程）

    nonisolated private static func transcribeOnBackground(
        engine: WhisperEngine, wav: URL, language: String,
        videoPath: String, self_ main: JobManager
    ) async throws -> (segments: [Segment], language: String) {
        let box = main.cancelBox
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(segments: [Segment], language: String), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result<(segments: [Segment], language: String), Error> {
                    try engine.run(wavURL: wav, language: language,
                                   progress: { pct in
                                       Task { @MainActor in
                                           main.updateTranscribeProgress(videoPath, pct: pct)
                                       }
                                   },
                                   isCancelled: { box.contains(videoPath) })
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

    private func withTimeout<T: Sendable>(seconds: TimeInterval, label: String,
                                          _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw JobError("\(label)超时（\(Int(seconds / 60)) 分钟）")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - 辅助

    nonisolated private func isCancelled(_ path: String) -> Bool {
        cancelBox.contains(path)
    }

    /// 语言码收敛（POC 调研结果：空/auto → orig）
    private func normalizeLanguage(_ lang: String) -> String {
        let l = lang.lowercased()
        return (l.isEmpty || l == "auto") ? "orig" : l
    }

    private func setStage(_ path: String, _ stage: Stage, pct: Double, detail: String) async throws {
        try Task.checkCancellation()
        if isCancelled(path) { throw CancellationError() }
        updateJob(path) {
            $0.stage = stage
            $0.pct = pct
            $0.detail = detail
        }
    }

    private func updateTranscribeProgress(_ path: String, pct: Int) {
        updateJob(path) {
            $0.pct = 5 + Double(pct) * 0.5
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

extension JobManager.Job {
    /// 菜单展示摘要
    var menuInfo: (title: String, pct: Double) {
        let name = URL(fileURLWithPath: videoPath).lastPathComponent
        return ("\(stage.rawValue) \(Int(pct))% · \(name)", pct)
    }
}
