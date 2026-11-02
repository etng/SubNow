import XCTest
@testable import SubNow

/// 抢占/暂停/续跑端到端（SUBNOW_E2E_PREEMPT=1 + 模型环境变量时运行）：
/// A 转录中 → 入队 B → A 暂停且保留音频 → B 跑完后 A 自动续跑并完成。
@MainActor
final class PreemptionE2ETests: XCTestCase {
    func testNewJobPreemptsRunningJobAndResumes() async throws {
        guard ProcessInfo.processInfo.environment["SUBNOW_E2E_PREEMPT"] == "1" else {
            throw XCTSkip("需要 SUBNOW_E2E_PREEMPT=1")
        }
        let env = ProcessInfo.processInfo.environment
        guard let modelPath = env["SUBNOW_SMOKE_MODEL"],
              let vadPath = env["SUBNOW_SMOKE_VAD"] else {
            throw XCTSkip("需要 SUBNOW_SMOKE_MODEL / SUBNOW_SMOKE_VAD")
        }
        let modelURL = URL(fileURLWithPath: modelPath)
        let vadURL = URL(fileURLWithPath: vadPath)
        guard modelURL.deletingLastPathComponent().path == vadURL.deletingLastPathComponent().path else {
            throw XCTSkip("模型与 VAD 需在同一目录（Config 只有一个 modelsDir）")
        }
        guard FFmpegLocator.locate() != nil else {
            throw XCTSkip("未找到 ffmpeg")
        }

        let cfg = Config.shared
        let savedModelsDir = cfg.modelsDir
        let savedDraft = cfg.draftModelFile
        let savedVad = cfg.vadModelFile
        let savedAutoFinal = cfg.autoFinal
        let savedTranslation = cfg.translationKind
        let savedConcurrent = cfg.maxConcurrent
        cfg.modelsDir = modelURL.deletingLastPathComponent()
        cfg.draftModelFile = modelURL.lastPathComponent
        cfg.vadModelFile = vadURL.lastPathComponent
        cfg.autoFinal = false
        cfg.translationKind = .none
        cfg.maxConcurrent = 1
        defer {
            cfg.modelsDir = savedModelsDir
            cfg.draftModelFile = savedDraft
            cfg.vadModelFile = savedVad
            cfg.autoFinal = savedAutoFinal
            cfg.translationKind = savedTranslation
            cfg.maxConcurrent = savedConcurrent
        }

        // 长素材保证 A 能停留在转录阶段；短素材让 B 快速跑完
        let long = try Self.sayWav(text: Self.longText, rate: 140)
        let short = try Self.sayWav(text: "Good morning. The weather is nice today.", rate: 180)
        defer {
            Self.removeOutputs(for: long)
            Self.removeOutputs(for: short)
        }

        let manager = JobManager.shared
        manager.enqueue(videoPath: long.path)
        try await Self.waitUntil(timeout: 180, "A 进入转录") {
            manager.jobs.first(where: { $0.videoPath == long.path })?.stage == .transcribe
        }

        // A 正在转录时插入 B：B 应立即抢占，A 暂停并保留工作目录
        manager.enqueue(videoPath: short.path)
        try await Self.waitUntil(timeout: 120, "A 被暂停") {
            manager.jobs.first(where: { $0.videoPath == long.path })?.stage == .paused
        }
        let paused = try XCTUnwrap(manager.jobs.first(where: { $0.videoPath == long.path }))
        XCTAssertTrue(paused.audioReady, "暂停前已提取的音频应保留")
        XCTAssertNotNil(paused.workDir, "暂停任务应保留工作目录")
        if let dir = paused.workDir {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
        }
        print("[preempt] A 已暂停于 \(Int(paused.pct))%，音频已保留")

        try await Self.waitUntil(timeout: 240, "B 完成") {
            manager.jobs.first(where: { $0.videoPath == short.path })?.stage == .done
        }
        try await Self.waitUntil(timeout: 300, "A 续跑完成") {
            manager.jobs.first(where: { $0.videoPath == long.path })?.stage == .done
        }

        let stem = long.deletingPathExtension().lastPathComponent
        let dir = long.deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).ass").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).zh.srt").path))
        print("[preempt] B 完成 → A 自动续跑并产出字幕")

        _ = await PlayerBook.shared.forget(pathPrefix: long.path)
        _ = await PlayerBook.shared.forget(pathPrefix: short.path)
    }

    // MARK: - helpers

    private static let longText = String(
        repeating: "The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs. "
            + "How vexingly quick daft zebras jump. Bright vixens jump; dozy fowl quack. ",
        count: 24)

    private static func sayWav(text: String, rate: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-preempt-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", String(rate), "-o", url.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "PreemptionE2E", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "say 合成失败"])
        }
        return url
    }

    private static func waitUntil(timeout: TimeInterval, _ label: String,
                                  _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("等待超时：\(label)")
        throw NSError(domain: "PreemptionE2E", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "等待超时：\(label)"])
    }

    private static func removeOutputs(for url: URL) {
        try? FileManager.default.removeItem(at: url)
        let dir = url.deletingLastPathComponent()
        let prefix = url.deletingPathExtension().lastPathComponent + "."
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}
