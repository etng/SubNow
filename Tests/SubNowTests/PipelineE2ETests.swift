import XCTest
@testable import SubNow

/// 本地流水线端到端（SUBNOW_E2E_LOCAL=1 时运行）：
/// say 合成语音 → 引擎转录 → 分行 → Ollama 真翻译 → SRT/ASS 落盘。
/// 验证「转录→翻译→产出文件」核心链路；播放器挂载部分由 IINA 真机 E2E 覆盖。
final class PipelineE2ETests: XCTestCase {
    func testLocalPipelineEndToEnd() async throws {
        guard ProcessInfo.processInfo.environment["SUBNOW_E2E_LOCAL"] == "1" else {
            throw XCTSkip("需要 SUBNOW_E2E_LOCAL=1")
        }
        guard let model = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_MODEL"],
              let vad = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_VAD"] else {
            throw XCTSkip("需要模型环境变量")
        }

        // ① 合成语音
        let wav = try Self.sayWav(text: "Good morning! The weather today is really nice. Let's go for a walk in the park.")
        defer { try? FileManager.default.removeItem(at: wav) }

        // ② 转录
        let engine = try WhisperEngine(modelURL: URL(fileURLWithPath: model), vadURL: URL(fileURLWithPath: vad))
        let (raw, language) = try engine.run(wavURL: wav, language: "auto", progress: { _ in }, isCancelled: { false })
        XCTAssertFalse(raw.isEmpty, "应有转录分段")
        print("[e2e] 语言=\(language) 分段=\(raw.count)")

        // ③ 分行长句（英文 → 非CJK 预算 44）
        let segments = Segments.splitLong(raw, language: language, lineLen: 20)
        print("[e2e] 分行后=\(segments.count)")
        for seg in segments.prefix(3) {
            print("[e2e]   [\(seg.start)-\(seg.end)] \(seg.src)")
        }

        // ④ Ollama 真翻译
        let translator = await Translator.make()
        let translations = try await translator.translate(segments: segments, language: language,
                                                          lineLen: 20, onBatch: nil, isCancelled: { false })
        XCTAssertFalse(translations.isEmpty, "Ollama 应产出译文")
        var zhSegments = segments
        for i in zhSegments.indices { zhSegments[i].zh = translations[i] ?? segments[i].src }
        for seg in zhSegments.prefix(3) {
            print("[e2e]   zh: \(seg.zh ?? "?")")
        }

        // ⑤ 落盘
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("subnow-e2e-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }
        try Writers.writeSrt(zhSegments, language: language, to: outDir.appendingPathComponent("test.en.srt"), mode: .original)
        try Writers.writeSrt(zhSegments, language: language, to: outDir.appendingPathComponent("test.zh.srt"), mode: .chinese)
        try Writers.writeBilingualAss(zhSegments, language: language, to: outDir.appendingPathComponent("test.ass"), zhFirst: true)
        try Writers.writeBilingualAss(zhSegments, language: language, to: outDir.appendingPathComponent("test.zh-bottom.ass"), zhFirst: false)
        try Writers.writeSegmentsFile(zhSegments, language: language, to: outDir.appendingPathComponent("test.segments.json"))

        // ⑥ 内容抽查
        let ass = try String(contentsOf: outDir.appendingPathComponent("test.ass"), encoding: .utf8)
        XCTAssertTrue(ass.contains("PlayResX: 1920"), "ASS 应有 PlayRes")
        XCTAssertTrue(ass.contains("Style: Zh,PingFang SC,56,&H00FFFFFF"), "中文字样式应精确匹配")
        XCTAssertTrue(ass.contains("Style: Org,PingFang SC,38,&H0050A8D0"), "原文金样式应精确匹配")
        XCTAssertTrue(ass.contains("{\\rZh}"), "Dialogue 应用 \\r 覆写")
        XCTAssertTrue(ass.contains("\\N"), "双语应两行")
        let srt = try String(contentsOf: outDir.appendingPathComponent("test.en.srt"), encoding: .utf8)
        XCTAssertTrue(srt.contains(" --> "), "SRT 应有时间轴")
        print("[e2e] 产物抽查通过（ass/srt/segments.json 均落盘）")
    }

    private static func sayWav(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-e2e-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        return url
    }
}
