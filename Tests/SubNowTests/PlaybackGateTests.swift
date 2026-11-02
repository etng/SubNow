import XCTest
@testable import SubNow

final class PlaybackGateTests: XCTestCase {
    func testGateFollowsPlayingStateOnSameVolume() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-gate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let playing = dir.appendingPathComponent("playing.mkv")
        let extracting = dir.appendingPathComponent("extracting.mkv")
        try Data("x".utf8).write(to: playing)
        try Data("y".utf8).write(to: extracting)

        let volume = try XCTUnwrap(PlaybackGate.volumePath(of: extracting.path))
        XCTAssertEqual(volume, PlaybackGate.volumePath(of: playing.path))

        let gate = PlaybackGate()
        gate.update(activities: [PlaybackActivity(path: playing.path, playing: true)])
        XCTAssertTrue(gate.isBusy(volumePath: volume))

        gate.update(activities: [PlaybackActivity(path: playing.path, playing: false)])
        XCTAssertFalse(gate.isBusy(volumePath: volume), "暂停中的播放器不应挡住提取")

        gate.update(activities: [])
        XCTAssertFalse(gate.isBusy(volumePath: volume))
        XCTAssertFalse(gate.isBusy(volumePath: nil))
    }

    func testPauseStatsAccumulates() throws {
        let stats = PauseStats()
        XCTAssertEqual(stats.pauseCount, 0)
        XCTAssertEqual(stats.pausedSeconds, 0, accuracy: 0.001)

        stats.beginPause()
        stats.beginPause()  // 重复调用不重复计数
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertGreaterThan(stats.pausedSeconds, 0.04)
        stats.endPause()
        XCTAssertEqual(stats.pauseCount, 1)
        let settled = stats.pausedSeconds
        XCTAssertGreaterThan(settled, 0.04)
        XCTAssertEqual(stats.pausedSeconds, settled, accuracy: 0.01)
    }

    /// 同一卷“正在播放”时提取应被 SIGSTOP；播放结束后 SIGCONT 并完成。
    func testExtractionPausesWhilePlaybackActive() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("video.mkv")
        try Data("v".utf8).write(to: video)
        let volume = try XCTUnwrap(PlaybackGate.volumePath(of: video.path))
        let ffmpeg = try Self.makeFakeFFmpeg(in: dir, sleep: 1)
        let wav = dir.appendingPathComponent("audio.wav")
        let stats = PauseStats()

        PlaybackGate.shared.update(activities: [PlaybackActivity(path: video.path, playing: true)])
        defer { PlaybackGate.shared.update(activities: []) }

        let task = Task {
            try await AudioExtractor.extract(video: video, to: wav, ffmpeg: ffmpeg,
                                             volumePath: volume,
                                             isCancelled: { false }, stats: stats)
        }
        try await Task.sleep(nanoseconds: 600_000_000)
        PlaybackGate.shared.update(activities: [])
        try await task.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        XCTAssertGreaterThanOrEqual(stats.pauseCount, 1, "播放期间应至少暂停一次")
        XCTAssertGreaterThan(stats.pausedSeconds, 0.4, "暂停时长应被计入")
    }

    /// 暂停状态下取消：必须先 SIGCONT 再终止，否则会一直等到超时。
    func testCancelWhilePausedFinishesPromptly() async throws {
        let dir = try Self.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("video.mkv")
        try Data("v".utf8).write(to: video)
        let volume = try XCTUnwrap(PlaybackGate.volumePath(of: video.path))
        let ffmpeg = try Self.makeFakeFFmpeg(in: dir, sleep: 10)
        let wav = dir.appendingPathComponent("audio.wav")
        let cancelled = LockedFlag()

        PlaybackGate.shared.update(activities: [PlaybackActivity(path: video.path, playing: true)])
        defer { PlaybackGate.shared.update(activities: []) }

        let task = Task {
            try await AudioExtractor.extract(video: video, to: wav, ffmpeg: ffmpeg,
                                             volumePath: volume,
                                             isCancelled: { cancelled.value })
        }
        try await Task.sleep(nanoseconds: 700_000_000)
        cancelled.value = true
        let started = Date()
        do {
            try await task.value
            XCTFail("应抛出取消错误")
        } catch is CancellationError {
            // expected
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0, "暂停中的 ffmpeg 应能被及时终止")
    }

    // MARK: - helpers

    private static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-pause-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 假 ffmpeg：睡一会儿后在最后一个参数（.part 输出路径）上创建文件。
    private static func makeFakeFFmpeg(in dir: URL, sleep: Int) throws -> URL {
        let script = dir.appendingPathComponent("fake-ffmpeg.sh")
        let body = """
        #!/bin/sh
        for last; do :; done
        sleep \(sleep)
        : > "$last"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
