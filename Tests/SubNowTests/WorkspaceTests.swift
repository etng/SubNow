import XCTest
@testable import SubNow

/// 工作区成品命名与历史记录读写。
final class WorkspaceTests: XCTestCase {
    func testOutputFileNames() {
        XCTAssertEqual(OutputKind.zhTopAss.fileName(stem: "Movie", language: "ja"), "Movie.ass")
        XCTAssertEqual(OutputKind.zhBottomAss.fileName(stem: "Movie", language: "ja"), "Movie.zh-bottom.ass")
        XCTAssertEqual(OutputKind.chineseSrt.fileName(stem: "Movie", language: "ja"), "Movie.zh.srt")
        XCTAssertEqual(OutputKind.originalSrt.fileName(stem: "Movie", language: "ja"), "Movie.ja.srt")
        XCTAssertEqual(OutputKind.originalSrt.fileName(stem: "Movie", language: "zh"), "Movie.orig.srt")
    }

    func testHistoryUpsertReplacesAndSorts() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("history.json")

        var older = record(key: "a", title: "E01", finishedAt: Date(timeIntervalSince1970: 100))
        let newer = record(key: "b", title: "E02", finishedAt: Date(timeIntervalSince1970: 200))
        HistoryStore.upsert(older, to: file)
        HistoryStore.upsert(newer, to: file)
        XCTAssertEqual(HistoryStore.load(from: file).map(\.key), ["b", "a"])

        older.status = "已归档"
        HistoryStore.upsert(older, to: file)
        let loaded = HistoryStore.load(from: file)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.key == "a" }?.status, "已归档")

        HistoryStore.remove(key: "b", from: file)
        XCTAssertEqual(HistoryStore.load(from: file).map(\.key), ["a"])
    }

    func testExportedKindsIgnoresUnknownValues() {
        var rec = record(key: "a", title: "E01", finishedAt: Date())
        rec.exported = ["zhTopAss", "chineseSrt", "legacy"]
        XCTAssertEqual(rec.exportedKinds(), [.zhTopAss, .chineseSrt])
    }

    private func record(key: String, title: String, finishedAt: Date) -> HistoryRecord {
        HistoryRecord(key: key, videoPath: "/tmp/\(title).mkv", title: title, language: "ja",
                      finishedAt: finishedAt, segmentCount: 10, status: "已完成",
                      workDir: "/tmp/job-\(key)", exported: ["zhTopAss"])
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-workspace-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
