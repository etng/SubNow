import XCTest
@testable import SubNow

/// 重启恢复端到端（SUBNOW_E2E_PERSIST=1 + SUBNOW_JOBS_FILE 指向临时文件时运行）：
/// 预置 jobs.json 检查点后启动 JobManager，暂停任务与失败重试都应复用音频/转录，
/// 不再重跑 ffmpeg/whisper。
@MainActor
final class PersistenceE2ETests: XCTestCase {
    func testPausedAndFailedJobsResumeFromCheckpoint() async throws {
        guard ProcessInfo.processInfo.environment["SUBNOW_E2E_PERSIST"] == "1" else {
            throw XCTSkip("需要 SUBNOW_E2E_PERSIST=1")
        }
        guard let jobsPath = ProcessInfo.processInfo.environment["SUBNOW_JOBS_FILE"], !jobsPath.isEmpty else {
            throw XCTSkip("需要 SUBNOW_JOBS_FILE 隔离任务表，避免污染真实用户数据")
        }
        XCTAssertEqual(Paths.jobsFile.path, jobsPath, "SUBNOW_JOBS_FILE 未生效")

        let pausedVideo = try Self.makeVideoFile("resume", bytes: 4096)
        let failedVideo = try Self.makeVideoFile("retry", bytes: 8192)
        defer {
            Self.removeOutputs(for: pausedVideo)
            Self.removeOutputs(for: failedVideo)
        }

        let paused = try Self.makeCheckpoint(
            for: pausedVideo, stage: .translate, pct: 58,
            text: "hello from the restart checkpoint test")
        let failed = try Self.makeCheckpoint(
            for: failedVideo, stage: .failed, pct: 30,
            text: "this failed job must retry from its checkpoint")
        defer {
            for rec in [paused, failed] {
                if let dir = rec.workDir { try? FileManager.default.removeItem(atPath: dir) }
            }
        }
        JobPersistence.write([paused.key: paused, failed.key: failed], to: Paths.jobsFile)
        // 源文件不可读：只要任务还能完成，就证明没有重跑 ffmpeg 提取
        for video in [pausedVideo, failedVideo] {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: video.path)
        }

        let cfg = Config.shared
        let savedAutoFinal = cfg.autoFinal
        let savedTranslation = cfg.translationKind
        cfg.autoFinal = false
        cfg.translationKind = .none
        defer {
            cfg.autoFinal = savedAutoFinal
            cfg.translationKind = savedTranslation
        }

        let manager = JobManager.shared
        let restored = try XCTUnwrap(manager.jobs.first(where: { $0.key == paused.key }),
                                     "启动时应从 jobs.json 载入暂停任务")
        XCTAssertEqual(restored.stage, .paused)
        XCTAssertTrue(restored.audioReady, "应复用已落盘的音频")
        XCTAssertNotNil(restored.draft, "应复用已完成的转录")
        let retry = try XCTUnwrap(manager.jobs.first(where: { $0.key == failed.key }),
                                  "启动时应从 jobs.json 载入失败任务")
        XCTAssertEqual(retry.stage, .failed, "失败任务保留检查点，等待重试")
        print("[persist] 启动载入：paused=\(restored.stage.rawValue) failed=\(retry.stage.rawValue)")

        manager.enqueue(videoPath: pausedVideo.path)
        try await Self.waitUntil(timeout: 90, "暂停任务恢复完成") {
            manager.jobs.first(where: { $0.key == paused.key })?.stage == .done
        }
        XCTAssertNil(JobPersistence.load(from: Paths.jobsFile)[paused.key], "完成后应清除持久化记录")
        XCTAssertTrue(Self.outputExists(for: pausedVideo), "应产出字幕文件")
        print("[persist] 暂停任务从检查点恢复完成，未重新提取音频")

        // 失败任务重试：走同样的检查点复用路径
        manager.enqueue(videoPath: failedVideo.path)
        try await Self.waitUntil(timeout: 90, "失败任务重试完成") {
            manager.jobs.first(where: { $0.key == failed.key })?.stage == .done
        }
        XCTAssertNil(JobPersistence.load(from: Paths.jobsFile)[failed.key], "重试完成后应清除持久化记录")
        XCTAssertTrue(Self.outputExists(for: failedVideo), "重试应产出字幕文件")
        print("[persist] 失败任务重试成功，未重新提取音频")

        for video in [pausedVideo, failedVideo] {
            _ = await PlayerBook.shared.forget(pathPrefix: video.path)
        }
    }

    // MARK: - helpers

    private static func makeVideoFile(_ tag: String, bytes: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-\(tag)-\(UUID().uuidString).mkv")
        try Data(repeating: 1, count: bytes).write(to: url)
        return url
    }

    private static func makeCheckpoint(for video: URL, stage: JobManager.Stage, pct: Double,
                                       text: String) throws -> PersistedJob {
        let key = JobKeys.path(video.path)
        let workDir = Paths.tmpDir.appendingPathComponent("job-\(key)", isDirectory: true)
        try? FileManager.default.removeItem(at: workDir)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        try sayWav(text: text, to: workDir.appendingPathComponent("audio.wav"))

        let draft = JobManager.Transcript(
            language: "en",
            segments: [Segment(start: 0, end: 2500, src: text, zh: nil)])
        return PersistedJob(
            videoPath: video.path,
            key: key,
            fingerprint: FileFingerprint.read(video.path),
            stage: stage.rawValue,
            pct: pct,
            detail: "测试检查点",
            workDir: workDir.path,
            audioReady: true,
            draft: draft,
            draftReady: false,
            final: nil,
            originalNotified: false,
            draftNotified: false,
            finalNotified: false,
            updatedAt: Date())
    }

    private static func sayWav(text: String, to url: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-r", "180", "-o", url.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "PersistenceE2E", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "say 合成失败"])
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ label: String,
                                  _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        XCTFail("等待超时：\(label)")
        throw NSError(domain: "PersistenceE2E", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "等待超时：\(label)"])
    }

    private static func outputExists(for video: URL) -> Bool {
        let stem = video.deletingPathExtension().lastPathComponent
        let dir = video.deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stem).ass").path)
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
