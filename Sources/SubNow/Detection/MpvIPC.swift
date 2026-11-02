import Foundation

/// mpv/IINA 的 JSON IPC 客户端（Unix socket，同步实现——调用方在后台队列使用）。
/// 协议：发送 {"command":[...]} + "\n"，读一行 JSON；3 秒超时。
enum MpvIPC {
    struct Track {
        let id: Int
        let type: String          // "sub" / "audio" / "video"
        let lang: String?
        let title: String?
        let selected: Bool
        let external: Bool
    }

    enum IPCError: Error, LocalizedError {
        case connectionFailed(String)
        case timeout
        case protocolError(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let p): return "无法连接 socket \(p)"
            case .timeout: return "IPC 超时"
            case .protocolError(let m): return "IPC 协议错误: \(m)"
            case .commandFailed(let m): return "mpv 命令失败: \(m)"
            }
        }
    }

    struct Reply {
        let error: String
        let data: Any?
    }

    // MARK: - 原子操作

    /// 执行一条 IPC 命令。socket 不可达返回 nil（探测语义），协议/命令错误抛异常。
    static func command(_ argv: [String], socketPath: String, timeout: TimeInterval = 3) -> Reply? {
        guard FileManager.default.fileExists(atPath: socketPath) else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: pathBytes) }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            cleanupDeadSocketIfNeeded(path: socketPath)
            return nil
        }

        // 接收超时
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var stv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &stv, socklen_t(MemoryLayout<timeval>.size))

        var payload: [String: Any] = ["command": argv]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return nil }

        var sent = 0
        let all = body + Data([0x0A])
        while sent < all.count {
            let n = all[(all.startIndex + sent)...].withContiguousStorageIfAvailable { buf -> Int in
                send(fd, buf.baseAddress, buf.count, 0)
            } ?? -1
            if n <= 0 { return nil }
            sent += n
        }

        var line = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                if line.isEmpty { return nil }  // 超时/断开：按"不可达"处理
                break
            }
            line.append(contentsOf: buf[0..<n])
            if let nl = line.firstIndex(of: 0x0A) {
                line = line[line.startIndex..<nl]
                break
            }
            if line.count > 1 << 20 { return nil }
        }

        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let error = obj["error"] as? String else {
            return nil
        }
        return Reply(error: error, data: obj["data"])
    }

    /// 死 socket 清理：连接拒绝且 mtime 超过 60s → unlink。
    /// 仅清理我们候选列表里的路径，绝不碰陌生 socket。
    static func cleanupDeadSocketIfNeeded(path: String) {
        let known = Set(Paths.socketCandidates)
        guard known.contains(path), let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else { return }
        if Date().timeIntervalSince(mtime) > 60 {
            try? FileManager.default.removeItem(atPath: path)
            Log.info("清理死 socket: \(path)")
        }
    }

    // MARK: - 语义化封装

    static func currentPath(socketPath: String) -> String? {
        guard let reply = command(["get_property", "path"], socketPath: socketPath),
              reply.error == "success" else { return nil }
        return reply.data as? String
    }

    static func trackList(socketPath: String) -> [Track]? {
        guard let reply = command(["get_property", "track-list"], socketPath: socketPath),
              reply.error == "success", let array = reply.data as? [[String: Any]] else { return nil }
        return array.map { dict in
            Track(
                id: dict["id"] as? Int ?? 0,
                type: dict["type"] as? String ?? "",
                lang: dict["lang"] as? String,
                title: dict["title"] as? String,
                selected: dict["selected"] as? Bool ?? false,
                external: dict["external"] as? Bool ?? false
            )
        }
    }

    /// 是否正在播放（有 path 即视为活跃，暂停也算）
    static func isAlive(socketPath: String) -> Bool {
        currentPath(socketPath: socketPath) != nil
    }

    // MARK: - 挂载（谁产出谁挂载：由流水线调用）

    static let originalTrackTitle = "原文（转录）"
    static let draftTrackTitle = "中文双语·粗稿"
    static let finalTrackTitle = "中文双语"

    /// 添加字幕轨并选中；成功后用 track-list 验证（按 title 匹配）
    @discardableResult
    static func subAdd(_ subFile: String, title: String, lang: String, socketPath: String) -> Bool {
        guard let reply = command(["sub-add", subFile, "select", title, lang], socketPath: socketPath),
              reply.error == "success" else { return false }
        return trackList(socketPath: socketPath)?.contains { $0.type == "sub" && $0.title == title } ?? false
    }

    /// 按标题移除字幕轨
    @discardableResult
    static func subRemove(byTitle title: String, socketPath: String) -> Bool {
        guard let tracks = trackList(socketPath: socketPath),
              let target = tracks.first(where: { $0.type == "sub" && $0.title == title }) else { return false }
        guard let reply = command(["sub-remove", String(target.id)], socketPath: socketPath),
              reply.error == "success" else { return false }
        return true
    }

    /// OSD 提示（4 秒）
    static func showText(_ text: String, socketPath: String) {
        _ = command(["show-text", text, "4000"], socketPath: socketPath)
    }

    /// 该 socket 播放的文件是否等于给定视频（挂载前必须校验）
    static func isPlaying(_ videoPath: String, socketPath: String) -> Bool {
        currentPath(socketPath: socketPath) == videoPath
    }

    /// 判断"当前已启用"的字幕轨里有没有中文（type=sub、selected、lang/title 指向中文）。
    /// 仅存在但未选中的中文轨不算——用户此刻屏幕上并没有中文字幕。
    static func hasChineseSubtitleTrack(tracks: [Track]) -> Bool {
        let zhLangs: Set<String> = ["zh", "chi", "zho", "zh-cn", "zh-tw", "zh-hans", "zh-hant", "yue"]
        return tracks.contains { track in
            guard track.type == "sub", track.selected else { return false }
            if let lang = track.lang?.lowercased(), zhLangs.contains(lang) { return true }
            if let title = track.title {
                if zhLangs.contains(title.lowercased()) { return true }
                if title.contains("中文") || title.contains("中字") || title.contains("简体") || title.contains("繁体") {
                    return true
                }
            }
            return false
        }
    }
}
