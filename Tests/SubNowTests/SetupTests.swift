import XCTest
@testable import SubNow

/// 下载器真实网络测试（SUBNOW_DL_TEST=1 时运行；下载 VAD 小模型到临时目录）
final class SetupTests: XCTestCase {
    func testModelDownloaderChunkedResume() async throws {
        guard ProcessInfo.processInfo.environment["SUBNOW_DL_TEST"] == "1" else {
            throw XCTSkip("需要 SUBNOW_DL_TEST=1")
        }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("subnow-dl-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dest) }

        let stream = try await ModelDownloader.shared.download(
            remote: HFSource.vadURL(file: Config.shared.vadModelFile),
            to: dest,
            label: "测试模型")
        var lastFraction: Double = -1
        var finished = false
        var failure: String?
        for await event in stream {
            switch event {
            case .progress(let frac, let detail):
                lastFraction = frac
                if frac >= 1 { print("[dl] \(detail)") }
            case .finished:
                finished = true
            case .failed(let message):
                failure = message
            }
        }
        XCTAssertNil(failure, "下载失败：\(failure ?? "")")
        XCTAssertTrue(finished, "应收到 finished 事件")
        XCTAssertEqual(lastFraction, 1.0, accuracy: 0.001)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int64) ?? 0
        XCTAssertGreaterThan(size, 500_000, "VAD 模型应 > 500KB")
    }

    func testComponentCenterOnThisMachine() async {
        await MainActor.run {
            ComponentCenter.shared.refresh()
            ComponentCenter.shared.refreshOllamaAsync()
            // 本机应已具备 ffmpeg + 模型 + Ollama（不强制，仅打印帮助人工核对）
            let center = ComponentCenter.shared
            print("[components] baseReady=\(center.isBaseReady) missing=\(center.missingSummary)")
            for id in ComponentCenter.ComponentID.allCases {
                if let st = center.status(id) {
                    print("[components] \(id.rawValue): \(st.state)")
                }
            }
        }
    }
}
