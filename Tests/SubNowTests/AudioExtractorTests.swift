import XCTest
@testable import SubNow

/// 真实 ffmpeg 集成测试：确认 progress 管道能驱动百分比，且 ffprobe 能给出时长。
/// 缺 ffmpeg/ffprobe 的环境直接跳过，不在 CI 上制造虚假失败。
final class AudioExtractorTests: XCTestCase {
    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Double?] = []

        func append(_ value: Double?) {
            lock.lock(); values.append(value); lock.unlock()
        }

        var snapshot: [Double?] {
            lock.lock(); defer { lock.unlock() }; return values
        }
    }

    func testExtractionReportsRealProgress() async throws {
        guard let ffmpeg = FFmpegLocator.locate(), let ffprobe = FFmpegLocator.locateFFprobe() else {
            throw XCTSkip("缺 ffmpeg/ffprobe")
        }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = dir.appendingPathComponent("clip.m4a")
        let gen = Process()
        gen.executableURL = ffmpeg
        gen.arguments = ["-y", "-loglevel", "error",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                         "-c:a", "aac", source.path]
        gen.standardError = FileHandle.nullDevice
        try gen.run()
        gen.waitUntilExit()
        XCTAssertEqual(gen.terminationStatus, 0)

        let duration = VideoProbe.durationSeconds(of: source, ffprobeURL: ffprobe)
        XCTAssertNotNil(duration)
        XCTAssertEqual(duration ?? 0, 4, accuracy: 0.5)

        let wav = dir.appendingPathComponent("audio.wav")
        let progress = ProgressBox()
        try await AudioExtractor.extract(
            video: source, to: wav, ffmpeg: ffmpeg,
            totalDuration: duration,
            isCancelled: { false },
            onProgress: { fraction, _ in progress.append(fraction) })

        XCTAssertTrue(FileManager.default.fileExists(atPath: wav.path))
        let fractions = progress.snapshot.compactMap { $0 }
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertGreaterThan(fractions.max() ?? 0, 0.9)
        XCTAssertEqual(fractions, fractions.sorted())
    }
}
