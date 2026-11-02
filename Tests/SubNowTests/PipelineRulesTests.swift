import XCTest
@testable import SubNow

/// 流水线与探测规则单测：颜色/转义/时间戳、分行与时间轴、记账失效、IPC 中文轨判定。
final class PipelineRulesTests: XCTestCase {
    // MARK: - ASS

    func testAssOriginalColorByteOrder() {
        // 目标 #D0A850；ASS 为 &HAABBGGRR，因此必须写成 &H0050A8D0
        XCTAssertTrue(Writers.assHeader().contains("Style: Org,PingFang SC,38,&H0050A8D0"))
        XCTAssertFalse(Writers.assHeader().contains("&H00850AD0"))
    }

    func testAssEscaping() {
        XCTAssertEqual(Writers.escapeAss("{x}"), "\\{x\\}")
        XCTAssertEqual(Writers.escapeAss("\\"), "\\\\")
        XCTAssertEqual(Writers.escapeAss("{\\r}"), "\\{\\\\r\\}")
    }

    func testWriteBilingualAssEscapesOverrides() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("a.ass")
        let segments = [Segment(start: 0, end: 1500, src: "hello {\\b1}world", zh: "你好")]
        try Writers.writeBilingualAss(segments, language: "en", to: url, zhFirst: true)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("{\\rZh}你好\\N{\\rOrg}hello \\{\\\\b1\\}world"))
    }

    func testSrtAndAssTimestamps() {
        XCTAssertEqual(Writers.tsSrt(3_661_001), "01:01:01,001")
        XCTAssertEqual(Writers.tsSrt(-5), "00:00:00,000")
        XCTAssertEqual(Writers.tsAss(3_661_001), "1:01:01.00")
        XCTAssertEqual(Writers.tsAss(59_999), "0:00:59.99")
    }

    func testOriginalSrtNamingAvoidsChineseOverride() {
        XCTAssertEqual(Writers.originalSrtName(stem: "Movie", language: "zh"), "Movie.orig.srt")
        XCTAssertEqual(Writers.originalSrtName(stem: "Movie", language: "en"), "Movie.en.srt")
    }

    // MARK: - 时间轴 / 分行

    func testFixTimingOverlapThenMinDuration() {
        let fixed = Segments.fixTiming([
            Segment(start: 0, end: 200, src: "a", zh: nil),
            Segment(start: 96, end: 336, src: "b", zh: nil),
            Segment(start: 1000, end: 1500, src: "c", zh: nil),
        ])
        XCTAssertEqual(fixed[0].start, 0)
        XCTAssertEqual(fixed[0].end, 800, "重叠修正后仍需满足 800ms 下限")
        XCTAssertEqual(fixed[1].start, 96)
        XCTAssertEqual(fixed[1].end, 896)
        XCTAssertEqual(fixed[2].end, 1800, "短段同样补到 800ms")
    }

    func testFixTimingCapsAtTenSeconds() {
        let fixed = Segments.fixTiming([Segment(start: 0, end: 30_000, src: "long", zh: nil)])
        XCTAssertEqual(fixed[0].end, 10_000)
    }

    func testSplitLongRefusesWhenTimingTooTight() {
        let text = String(repeating: "あ", count: 60)
        let out = Segments.splitLong(
            [Segment(start: 0, end: 1000, src: text, zh: nil)], language: "ja", lineLen: 20)
        XCTAssertEqual(out.count, 1, "时间不够分片时应保持整段")
        XCTAssertEqual(out[0].src, text)
    }

    func testSplitLongSplitsWithEnoughTiming() {
        let text = String(repeating: "あ", count: 60)
        let out = Segments.splitLong(
            [Segment(start: 0, end: 5000, src: text, zh: nil)], language: "ja", lineLen: 20)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out.last?.end, 5000)
        XCTAssertTrue(out.allSatisfy { $0.end - $0.start >= 800 })
    }

    func testWrapLineHardCut() {
        XCTAssertEqual(Segments.wrapLine("abcdefghijklmno", width: 10, joiner: "\n"),
                       "abcdefghij\nklmno")
        XCTAssertEqual(Segments.wrapLine("short", width: 10, joiner: "\n"), "short")
    }

    func testCleanTextStripsLeadingPunctuation() {
        XCTAssertEqual(Segments.cleanText("  ，。你好  "), "你好")
    }

    // MARK: - 探测 / 记账

    func testSidecarDetection() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("Movie.mkv")
        FileManager.default.createFile(atPath: video.path, contents: nil)

        XCTAssertFalse(VideoProbe.sidecarExists(for: video).exists)
        FileManager.default.createFile(atPath: dir.appendingPathComponent("Movie.zh.srt").path, contents: nil)
        let result = VideoProbe.sidecarExists(for: video)
        XCTAssertTrue(result.exists)
        XCTAssertTrue(result.isChinese)
    }

    func testChineseTrackRequiresSelectedSubtitle() {
        let unselected = MpvIPC.Track(id: 1, type: "sub", lang: "zh", title: nil,
                                      selected: false, external: false)
        XCTAssertFalse(MpvIPC.hasChineseSubtitleTrack(tracks: [unselected]))

        let selected = MpvIPC.Track(id: 2, type: "sub", lang: "zh-cn", title: nil,
                                    selected: true, external: false)
        XCTAssertTrue(MpvIPC.hasChineseSubtitleTrack(tracks: [selected]))

        let audio = MpvIPC.Track(id: 3, type: "audio", lang: "zh", title: nil,
                                 selected: true, external: false)
        XCTAssertFalse(MpvIPC.hasChineseSubtitleTrack(tracks: [audio]))
    }

    func testPlayerBookSidecarInvalidation() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("Movie.mkv")
        FileManager.default.createFile(atPath: video.path, contents: nil)
        let state = dir.appendingPathComponent("state.json")

        let book = PlayerBook(fileURL: state)
        await book.set("has-subs", for: video, sidecar: true)
        let skipWhileSidecarExists = await book.shouldSkip(video: video, sidecarExistsNow: true)
        XCTAssertTrue(skipWhileSidecarExists)

        let skipAfterRemoval = await book.shouldSkip(video: video, sidecarExistsNow: false)
        XCTAssertFalse(skipAfterRemoval, "外挂字幕被删除后应重新判定")
    }

    func testPlayerBookConvertsInterruptedJobToQueuedRestart() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let video = dir.appendingPathComponent("Movie.mkv")
        FileManager.default.createFile(atPath: video.path, contents: nil)
        let state = dir.appendingPathComponent("state.json")

        let first = PlayerBook(fileURL: state)
        await first.set("processing", for: video, sidecar: false)

        let reopened = PlayerBook(fileURL: state)
        let paths = await reopened.queuedRestartPaths()
        XCTAssertEqual(paths, [video.path])
    }

    // MARK: - Provider 地址

    func testOllamaChatURLNormalizesTrailingSlash() throws {
        XCTAssertEqual(try OllamaProvider.chatURL("http://127.0.0.1:11434/").absoluteString,
                       "http://127.0.0.1:11434/api/chat")
        XCTAssertEqual(try OllamaProvider.chatURL("http://127.0.0.1:11434///").absoluteString,
                       "http://127.0.0.1:11434/api/chat")
    }

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
