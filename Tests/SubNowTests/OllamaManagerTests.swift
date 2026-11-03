import XCTest
@testable import SubNow

final class OllamaManagerTests: XCTestCase {
    func testLoopbackDetection() {
        XCTAssertTrue(OllamaManager.isLoopback("http://127.0.0.1:11434"))
        XCTAssertTrue(OllamaManager.isLoopback("http://127.0.0.1"))
        XCTAssertTrue(OllamaManager.isLoopback("http://localhost:11434/"))
        XCTAssertTrue(OllamaManager.isLoopback("http://[::1]:11434"))
        XCTAssertFalse(OllamaManager.isLoopback("http://192.168.1.10:11434"))
        XCTAssertFalse(OllamaManager.isLoopback("https://ollama.example.com"))
        XCTAssertFalse(OllamaManager.isLoopback(""))
    }
}
