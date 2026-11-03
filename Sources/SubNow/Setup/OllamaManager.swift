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
    /// SubNow 实际请求过的模型（按服务地址分组）；空闲回收只动这些，绝不碰其他程序加载的模型。
    private var usedModels: [String: Set<String>] = [:]

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

    // MARK: - 空闲回收

    /// 记下 SubNow 实际请求过的模型，供任务停下后按需卸载。
    func noteUsed(model: String, baseURL: String) {
        let name = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { usedModels[Self.endpointKey(baseURL), default: []].insert(name) }
    }

    /// 任务全部停下后调用：只在本机 Ollama、且没有其他客户端连接时，
    /// 卸载 SubNow 用过的模型。不停止 ollama serve，也不动别人的模型。
    func releaseIdleModels(baseURL: String) async {
        guard Self.isLoopback(baseURL) else { return }
        let key = Self.endpointKey(baseURL)
        let candidates = usedModels[key] ?? []
        guard !candidates.isEmpty else { return }
        guard !Self.hasOtherClients(baseURL: baseURL) else {
            Log.info("Ollama 仍有其他客户端连接，保留模型")
            return
        }
        guard let loaded = await loadedModels(baseURL: baseURL) else { return }
        let targets = candidates.intersection(loaded)
        guard !targets.isEmpty else {
            // 已经被 keep_alive 自动卸掉，清掉记账即可
            usedModels[key] = nil
            return
        }
        var released: [String] = []
        for model in targets {
            if await unload(model: model, baseURL: baseURL) {
                released.append(model)
                usedModels[key]?.remove(model)
            }
        }
        if usedModels[key]?.isEmpty == true { usedModels[key] = nil }
        if !released.isEmpty {
            Log.info("已释放 Ollama 模型：\(released.joined(separator: "、"))")
        }
    }

    /// GET /api/ps → 当前驻留的模型名；失败返回 nil（不贸然卸载）。
    private func loadedModels(baseURL: String) async -> Set<String>? {
        guard let url = try? Self.endpoint(baseURL, "/api/ps") else { return nil }
        let request = URLRequest(url: url, timeoutInterval: 4)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return nil
        }
        struct Ps: Decodable {
            struct M: Decodable { let name: String; let model: String? }
            let models: [M]
        }
        guard let ps = try? JSONDecoder().decode(Ps.self, from: data) else { return nil }
        return Set(ps.models.flatMap { [$0.name, $0.model].compactMap { $0 } })
    }

    /// POST /api/generate，keep_alive=0 即刻卸载（空 prompt 不会触发推理）。
    private func unload(model: String, baseURL: String) async -> Bool {
        guard let url = try? Self.endpoint(baseURL, "/api/generate") else { return false }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "keep_alive": 0,
        ])
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            return false
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = obj["error"] as? String {
            Log.warn("卸载 Ollama 模型失败 \(model): \(error)")
            return false
        }
        return true
    }

    /// 服务地址归一（host:port），用于隔离不同 Ollama 实例的模型记账。
    private static func endpointKey(_ baseURL: String) -> String {
        guard let comps = URLComponents(string: baseURL), let host = comps.host?.lowercased() else {
            return baseURL
        }
        return "\(host):\(comps.port ?? 11434)"
    }

    /// 只回收本机 Ollama；远端服务可能多人共用，绝不擅自卸载。
    static func isLoopback(_ baseURL: String) -> Bool {
        guard let raw = URLComponents(string: baseURL)?.host?.lowercased() else { return false }
        // Foundation 对 IPv6 会保留方括号（[::1]）
        let host = raw.hasPrefix("[") && raw.hasSuffix("]")
            ? String(raw.dropFirst().dropLast()) : raw
        return host == "localhost" || host == "::1" || host.hasPrefix("127.")
    }

    /// 该端口上是否有 SubNow 以外的客户端。
    /// 回环连接在 lsof 里会同时出现客户端和服务端两条记录，先排除监听进程；
    /// Ollama.app 自身（大写 Ollama 的 GUI）会常驻几条状态连接，也不算外部客户端。
    /// lsof 不可用/超时等无法判断的情况按“有”处理，宁可不回收。
    private static func hasOtherClients(baseURL: String) -> Bool {
        let port = URLComponents(string: baseURL)?.port ?? 11434
        guard let established = lsofProcesses(port: port, state: "ESTABLISHED"),
              let listeners = lsofProcesses(port: port, state: "LISTEN") else { return true }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let listenerPIDs = Set(listeners.map(\.pid))
        return established.contains { proc in
            proc.pid != ownPID
                && !listenerPIDs.contains(proc.pid)
                && proc.command.lowercased() != "ollama"
        }
    }

    private struct LsofProcess {
        let pid: Int32
        let command: String
    }

    /// lsof 按 pid/命令列出指定端口状态的进程；失败返回 nil。
    private static func lsofProcesses(port: Int, state: String) -> [LsofProcess]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:\(state)", "-Fpc"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // lsof：有匹配返回 0，无匹配返回 1
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { return nil }
        var result: [LsofProcess] = []
        var pid: Int32?
        var command = ""
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            if line.hasPrefix("p") {
                if let pid { result.append(LsofProcess(pid: pid, command: command)) }
                pid = Int32(line.dropFirst())
                command = ""
            } else if line.hasPrefix("c") {
                command = String(line.dropFirst())
            }
        }
        if let pid { result.append(LsofProcess(pid: pid, command: command)) }
        return result
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
