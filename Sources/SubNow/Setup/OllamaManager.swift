import Foundation

/// Ollama 服务管理：探测、列模型、拉模型（/api/pull 流式进度）。
actor OllamaManager {
    static let shared = OllamaManager()

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    enum PullEvent {
        case progress(fraction: Double, status: String)
        case done
        case failed(String)
    }

    private var cachedModels: [String] = []
    private var lastProbe: Date?

    /// GET /api/tags → 已安装模型名列表
    func listModels(baseURL: String, timeout: TimeInterval = 4) async throws -> [String] {
        let url = try tagsURL(baseURL)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError(message: "Ollama 服务无响应")
        }
        struct Tags: Decodable { struct M: Decodable { let name: String }; let models: [M] }
        let tags = try JSONDecoder().decode(Tags.self, from: data)
        cachedModels = tags.models.map(\.name)
        lastProbe = Date()
        return cachedModels
    }

    /// POST /api/pull，NDJSON 流式进度
    func pull(baseURL: String, model: String) async throws -> AsyncStream<PullEvent> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await Self.performPull(baseURL: baseURL, model: model) { frac, status in
                        continuation.yield(.progress(fraction: frac, status: status))
                    }
                    continuation.yield(.done)
                } catch is CancellationError {
                    continuation.yield(.failed("已取消"))
                } catch {
                    Log.error("拉取模型失败 \(model): \(error.localizedDescription)")
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func performPull(baseURL: String, model: String,
                                    report: @escaping (Double, String) -> Void) async throws {
        var request = URLRequest(url: try pullURL(baseURL), timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OllamaError(message: "Ollama 拉取请求失败（服务未启动？）")
        }

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if let err = obj["error"] as? String {
                throw OllamaError(message: err)
            }
            let status = obj["status"] as? String ?? ""
            if let total = obj["total"] as? Double, let completed = obj["completed"] as? Double, total > 0 {
                report(completed / total, "\(model) \(Int(completed / total * 100))%")
            } else if !status.isEmpty {
                report(-1, "\(model) \(status)")
            }
            if status == "success" { break }
        }
        Log.info("Ollama 模型拉取完成: \(model)")
    }

    private func tagsURL(_ base: String) throws -> URL {
        try Self.endpoint(base, "/api/tags")
    }

    private static func pullURL(_ base: String) throws -> URL {
        try endpoint(base, "/api/pull")
    }

    /// 兼容末尾带斜杠的地址，避免拼出 //api/tags
    private static func endpoint(_ base: String, _ path: String) throws -> URL {
        var trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty, let url = URL(string: trimmed + path) else {
            throw OllamaError(message: "Ollama 地址无效")
        }
        return url
    }
}
