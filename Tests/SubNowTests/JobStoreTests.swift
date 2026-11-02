import XCTest
@testable import SubNow

final class JobStoreTests: XCTestCase {
    func testPathKeyIsStableAcrossPathForms() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let video = dir.appendingPathComponent("movie.mkv")
        try Data("x".utf8).write(to: video)
        let symlink = dir.appendingPathComponent("alias.mkv")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: video)

        let canonical = JobKeys.path(video.path)
        XCTAssertEqual(canonical, JobKeys.path(video.path))
        XCTAssertEqual(canonical, JobKeys.path(symlink.path), "符号链接应指向同一条任务记录")
        XCTAssertEqual(canonical, JobKeys.path(dir.appendingPathComponent("./movie.mkv").path))
        XCTAssertEqual(canonical.count, 16)

        let other = dir.appendingPathComponent("other.mkv")
        XCTAssertNotEqual(canonical, JobKeys.path(other.path))
    }

    func testFingerprintChangesWhenFileChanges() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-fp-\(UUID().uuidString).mkv")
        try Data(repeating: 0, count: 16).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        let first = try XCTUnwrap(FileFingerprint.read(file.path))
        XCTAssertEqual(first.size, 16)

        try Data(repeating: 0, count: 32).write(to: file)
        let second = try XCTUnwrap(FileFingerprint.read(file.path))
        XCTAssertNotEqual(first.size, second.size)
        XCTAssertNotEqual(first, second)
    }

    func testPersistenceRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-jobs-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let transcript = JobManager.Transcript(
            language: "en",
            segments: [Segment(start: 0, end: 1200, src: "hello", zh: "你好")])
        let record = PersistedJob(
            videoPath: "/tmp/movie.mkv",
            key: JobKeys.path("/tmp/movie.mkv"),
            fingerprint: FileFingerprint(size: 42, mtime: 1_700_000_000),
            stage: JobManager.Stage.translate.rawValue,
            pct: 61,
            detail: "翻译（草稿） 2/5 批",
            workDir: "/tmp/job-deadbeef",
            audioReady: true,
            draft: transcript,
            draftReady: false,
            final: nil,
            originalNotified: true,
            draftNotified: false,
            finalNotified: false,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))

        JobPersistence.write([record.key: record], to: url)
        let loaded = JobPersistence.load(from: url)
        let restored = try XCTUnwrap(loaded[record.key])
        XCTAssertEqual(restored.videoPath, record.videoPath)
        XCTAssertEqual(restored.stage, "翻译")
        XCTAssertEqual(restored.audioReady, true)
        XCTAssertEqual(restored.draft?.segments.first?.src, "hello")
        XCTAssertEqual(restored.draft?.segments.first?.zh, "你好")
    }

    func testCorruptFileLoadsAsEmpty() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-jobs-bad-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(JobPersistence.load(from: url).isEmpty)
    }
}
