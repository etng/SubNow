import XCTest
import WhisperBridge

/// 引擎冒烟：加载真实 ggml 模型，验证 Metal + VAD + 转录取段全链路。
/// 需要 SUBNOW_SMOKE_MODEL 指向模型文件；SUBNOW_SMOKE_VAD 指向 Silero VAD 模型。
final class WhisperSmokeTests: XCTestCase {
    func testEngineWithSilenceAndVAD() throws {
        guard let model = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_MODEL"],
              let vad = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_VAD"],
              !model.isEmpty, !vad.isEmpty else {
            throw XCTSkip("需要 SUBNOW_SMOKE_MODEL 与 SUBNOW_SMOKE_VAD 环境变量")
        }
        try Self.withContext(model: model, vad: vad) { ctx in
            // 纯静音 + VAD：等价于"无语音"，应成功返回 0 段
            let wav = Self.writeWav(seconds: 1, sampleRate: 16000, samples: { _ in 0 })
            defer { try? FileManager.default.removeItem(at: wav) }
            try Self.run(ctx: ctx, wav: wav, language: "auto")
        }
    }

    func testEngineWithRealSpeech() throws {
        guard let model = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_MODEL"],
              let vad = ProcessInfo.processInfo.environment["SUBNOW_SMOKE_VAD"],
              !model.isEmpty, !vad.isEmpty else {
            throw XCTSkip("需要 SUBNOW_SMOKE_MODEL 与 SUBNOW_SMOKE_VAD 环境变量")
        }
        try Self.withContext(model: model, vad: vad) { ctx in
            let wav = try Self.sayWav(text: "Hello, this is a smoke test for the SubNow subtitle engine.")
            defer { try? FileManager.default.removeItem(at: wav) }
            try Self.run(ctx: ctx, wav: wav, language: "en")

            let n = snwh_segment_count(ctx)
            XCTAssertGreaterThan(n, 0, "真实语音应产生分段")
            let lang = Self.cString(snwh_detected_language(ctx))
            XCTAssertEqual(lang, "en")
            if n > 0 {
                let text = Self.cString(snwh_segment_text(ctx, 0))
                print("[smoke] 首段: t0=\(snwh_segment_t0(ctx, 0))ms t1=\(snwh_segment_t1(ctx, 0))ms text=\(text.prefix(60))")
            }
        }
    }

    // MARK: - Helpers

    private static func withContext(model: String, vad: String, _ body: (OpaquePointer) throws -> Void) throws {
        var err = [CChar](repeating: 0, count: 1024)
        guard let ctx = model.withCString({ snwh_load($0, vad, &err, 1024) }) else {
            XCTFail("模型加载失败: \(String(cString: err))")
            return
        }
        defer { snwh_free(ctx) }
        try body(ctx)
    }

    private static func run(ctx: OpaquePointer, wav: URL, language: String) throws {
        var err = [CChar](repeating: 0, count: 1024)
        let rc = wav.path.withCString { path in
            language.withCString { lang in
                snwh_run(ctx, path, lang, nil, nil, nil, nil, &err, 1024)
            }
        }
        XCTAssertEqual(rc, 0, "whisper run 失败: \(String(cString: err))")
    }

    private static func cString(_ ptr: UnsafePointer<CChar>?) -> String {
        ptr.map { String(cString: $0) } ?? ""
    }

    /// 用 macOS 自带 say 合成 16kHz 单声道 PCM16 WAV（不依赖 ffmpeg）
    private static func sayWav(text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-say-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        p.arguments = ["-o", url.path, "--data-format=LEI16@16000", text]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0, "say 合成失败")
        return url
    }

    private static func writeWav(seconds: Int, sampleRate: Int, samples: (Int) -> Int16) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-gen-\(UUID().uuidString).wav")
        let n = seconds * sampleRate
        var pcm = Data(capacity: n * 2)
        for i in 0..<n {
            var v = samples(i).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var data = Data()
        func str(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + pcm.count)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(pcm.count)); data.append(pcm)
        try? data.write(to: url)
        return url
    }
}
