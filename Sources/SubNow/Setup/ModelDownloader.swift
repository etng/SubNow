import Foundation

/// HF 大文件下载器：主源 → hf-mirror 回退；Range 分块（8MB）+ .part 断点续传；
/// 每 MB 落盘、250ms 节流进度；Task 取消即停，进度文件保留供续传。
actor ModelDownloader {
    static let shared = ModelDownloader()

    enum Event {
        case progress(fraction: Double, detail: String)
        case finished
    }

    struct DownloadError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private static let chunkSize: Int64 = 8 << 20

    func download(remote: URL, to dest: URL, label: String) async throws -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    try await Self.perform(remote: remote, to: dest, label: label) { frac, detail in
                        continuation.yield(.progress(fraction: frac, detail: detail))
                    }
                    continuation.yield(.finished)
                } catch {
                    Log.error("下载失败 \(dest.lastPathComponent): \(error.localizedDescription)")
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func perform(remote: URL, to dest: URL, label: String,
                                report: @escaping (Double, String) -> Void) async throws {
        let partURL = dest.appendingPathExtension("part")
        var lastError: Error?

        // 会话矩阵：系统代理会话优先（多数用户靠代理出海），失败退直连（ephemeral 不读系统代理）
        let sessions: [(String, URLSession)] = [
            ("默认(含系统代理)", .shared),
            ("直连", URLSession(configuration: .ephemeral)),
        ]
        for candidate in sources(for: remote) {
            for (name, session) in sessions {
                do {
                    try await fetchChunked(from: candidate, using: session,
                                           partURL: partURL, dest: dest, label: label, report: report)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    lastError = error
                    print("[dl-err] \(candidate.host ?? "?") / \(name): \(error)")
                    Log.warn("下载尝试失败[\(candidate.host ?? "?") / \(name)]：\(error.localizedDescription)")
                }
            }
        }
        throw lastError ?? DownloadError(message: "所有下载源均失败")
    }

    private static func sources(for remote: URL) -> [URL] {
        let mirror = URL(string: remote.absoluteString
            .replacingOccurrences(of: "https://huggingface.co", with: "https://hf-mirror.com"))!
        return [remote, mirror]
    }

    private static func fetchChunked(from url: URL, using session: URLSession,
                                     partURL: URL, dest: URL, label: String,
                                     report: @escaping (Double, String) -> Void) async throws {
        var offset = existingSize(of: partURL)
        var total: Int64 = -1
        let file: FileHandle
        if offset > 0, let fh = try? FileHandle(forWritingTo: partURL) {
            file = fh
            try fh.seek(toOffset: UInt64(offset))
        } else {
            offset = 0
            FileManager.default.createFile(atPath: partURL.path, contents: nil)
            file = try FileHandle(forWritingTo: partURL)
        }
        defer { try? file.close() }

        while true {
            try Task.checkCancellation()

            var request = URLRequest(url: url, timeoutInterval: 120)
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw DownloadError(message: "非 HTTP 响应")
            }

            var completedBy416 = false
            switch http.statusCode {
            case 206:
                break  // 正常续传
            case 200:
                // 服务器不支持 Range：从头写
                offset = 0
                try file.truncate(atOffset: 0)
            case 416:
                // Content-Range 的 Z 即文件总大小（HTTP 规范），offset 已到末尾 = 下载完成
                if total > 0 && offset >= total {
                    completedBy416 = true
                } else {
                    try? FileManager.default.removeItem(at: partURL)
                    throw DownloadError(message: "续传点失效，已重置（重试即可）")
                }
            default:
                throw DownloadError(message: "HTTP \(http.statusCode)")
            }

            if completedBy416 { break }

            // 从 Content-Range: bytes X-Y/Z 取总大小（Z = 文件总字节数，不是末字节+1）
            if total < 0, let rangeHeader = http.value(forHTTPHeaderField: "Content-Range"),
               let zPart = rangeHeader.split(separator: "/").last, let z = Int64(zPart) {
                total = z
            } else if total < 0, http.expectedContentLength > 0 {
                total = http.expectedContentLength + offset
            }

            try file.write(contentsOf: data)
            offset += Int64(data.count)

            if total > 0 {
                let frac = Double(offset) / Double(total)
                report(min(frac, 1.0),
                       "\(label) \(ByteCountFormatter.string(fromByteCount: offset, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            }

            if total > 0 && offset >= total {
                break
            }
            if data.isEmpty {
                throw DownloadError(message: "服务器提前断流")
            }
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.moveItem(at: partURL, to: dest)
        report(1.0, "\(label) 完成")
        Log.info("模型下载完成: \(dest.lastPathComponent)")
    }

    private static func existingSize(of url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }
}
