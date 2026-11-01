import AppKit
import Darwin

/// 播放器监控：周期轮询 IINA / mpv。
/// 首选 IPC socket（精确知道"当前加载了什么字幕轨"），无 socket 时 lsof 兜底找视频文件。
@MainActor
final class PlayerMonitor {
    struct Playback {
        let player: String          // "IINA" / "mpv"
        let pid: Int32
        let videoPath: String
        let viaIPC: Bool            // true=socket 精确判定；false=lsof 兜底（文件级判定）
        let socketPath: String?
        let loadedChineseSubtitle: Bool?  // 仅 IPC 可判定
    }

    struct Snapshot {
        let playbacks: [Playback]
        let iinaConfiguredForIPC: Bool   // IINA 在跑但无 socket → 设置界面要提醒
    }

    /// 菜单栏展示用的播放摘要
    struct PlaybackMenuInfo {
        let videoName: String
        let player: String
        let videoPath: String
        let subtitleState: String
    }

    /// 轮询用的冻结配置（每轮从主线程快照，避免后台线程跨 Actor 读 Config）
    struct FrozenConfig {
        let pollSeconds: Double
        let minFileMB: Int
        let customSocketPath: String
        let socketCandidates: [String]

        @MainActor
        init(from config: Config) {
            pollSeconds = config.pollSeconds
            minFileMB = config.minFileMB
            customSocketPath = config.customSocketPath
            socketCandidates = Paths.socketCandidates
        }
    }

    /// mpv pid → argv 中的 --input-ipc-server（带锁缓存，跨线程读写）
    private final class ArgvSocketCache: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [Int32: String] = [:]
        func get(_ pid: Int32) -> String? { lock.lock(); defer { lock.unlock() }; return map[pid] }
        func set(_ pid: Int32, _ value: String) { lock.lock(); map[pid] = value; lock.unlock() }
    }

    private var task: Task<Void, Never>?
    private var lastSnapshot: Snapshot?
    private var lastIINAWithoutIPC = false
    private let argvCache = ArgvSocketCache()

    /// 每轮轮询回调（主线程）
    var onPlayback: ((Snapshot) -> Void)?

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let config = await FrozenConfig(from: Config.shared)
                let snapshot = await Self.poll(config: config, argvCache: self.argvCache)
                self.lastSnapshot = snapshot
                self.lastIINAWithoutIPC = snapshot.iinaConfiguredForIPC
                self.onPlayback?(snapshot)
                try? await Task.sleep(nanoseconds: UInt64(config.pollSeconds * 1_000_000_000))
            }
        }
        Log.info("播放器监控已启动（间隔 \(Int(FrozenConfig(from: Config.shared).pollSeconds))s）")
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    var iinaNeedsIPCSetup: Bool { lastIINAWithoutIPC }
    var currentSnapshot: Snapshot? { lastSnapshot }

    // MARK: - 轮询实现（后台）

    nonisolated private static func poll(config: FrozenConfig, argvCache: ArgvSocketCache) async -> Snapshot {
        let players = findPlayers()

        var playbacks: [Playback] = []
        var seenPaths = Set<String>()
        var iinaWithoutIPC = false

        for (pid, name) in players {
            let sockets = socketCandidates(for: name, pid: pid, config: config, argvCache: argvCache)

            // ① IPC 优先：能报出 path 就信任 socket
            var handled = false
            for sock in sockets {
                guard let path = MpvIPC.currentPath(socketPath: sock) else { continue }
                handled = true
                guard VideoProbe.isVideoFile(URL(fileURLWithPath: path)),
                      !seenPaths.contains(path),
                      fileSizeOK(path, minMB: config.minFileMB) else { break }
                let tracks = MpvIPC.trackList(socketPath: sock)
                let hasZH = tracks.map { MpvIPC.hasChineseSubtitleTrack(tracks: $0) }
                playbacks.append(Playback(player: name, pid: pid, videoPath: path,
                                          viaIPC: true, socketPath: sock,
                                          loadedChineseSubtitle: hasZH))
                seenPaths.insert(path)
                break
            }
            if handled {
                if name == "IINA" { iinaWithoutIPC = false }
                continue
            }

            // ② lsof 兜底（播放器在跑但拿不到 IPC）
            guard let video = await openVideoFile(pid: pid) else {
                if name == "IINA" { iinaWithoutIPC = true }
                continue
            }
            if seenPaths.contains(video.path) { continue }
            guard fileSizeOK(video.path, minMB: config.minFileMB) else { continue }
            playbacks.append(Playback(player: name, pid: pid, videoPath: video.path,
                                      viaIPC: false, socketPath: nil,
                                      loadedChineseSubtitle: nil))
            seenPaths.insert(video.path)
            if name == "IINA" { iinaWithoutIPC = false }
        }

        return Snapshot(playbacks: playbacks, iinaConfiguredForIPC: iinaWithoutIPC)
    }

    /// 找运行中的播放器：GUI 应用按 Bundle ID，mpv CLI 按可执行名
    nonisolated private static func findPlayers() -> [(Int32, String)] {
        var result: [(Int32, String)] = []
        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular, let bid = app.bundleIdentifier else { continue }
            if bid == "com.colliderli.iina" {
                result.append((app.processIdentifier, "IINA"))
            } else if bid.hasPrefix("io.mpv") {
                result.append((app.processIdentifier, "mpv"))
            }
        }
        // CLI mpv（无 Bundle）
        for pid in processPids() where !result.contains(where: { $0.0 == pid }) {
            if let path = executablePath(pid: pid), path.hasSuffix("/mpv") {
                result.append((pid, "mpv"))
            }
        }
        return result
    }

    /// socket 候选：用户自定义 → argv 里的 --input-ipc-server（仅 mpv）→ 默认/默认候选
    nonisolated private static func socketCandidates(for player: String, pid: Int32,
                                                     config: FrozenConfig,
                                                     argvCache: ArgvSocketCache) -> [String] {
        var list: [String] = []
        if !config.customSocketPath.isEmpty { list.append(config.customSocketPath) }
        if player == "mpv" {
            if let cached = argvCache.get(pid) {
                list.append(cached)
            } else if let sock = argvSocket(pid: pid) {
                argvCache.set(pid, sock)
                list.append(sock)
            }
        }
        list += config.socketCandidates
        return list
    }

    /// lsof 找该进程打开的视频文件（第一条命中；排除系统目录）
    nonisolated private static func openVideoFile(pid: Int32) async -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-p", String(pid), "-F", "n"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice

        do {
            try p.run()
            let done = DispatchSemaphore(value: 0)
            p.terminationHandler = { _ in done.signal() }
            let deadline = DispatchTime.now() + 10
            if done.wait(timeout: deadline) == .timedOut {
                p.terminate()
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            let home = NSHomeDirectory()
            for line in text.split(separator: "\n") {
                guard line.hasPrefix("n") else { continue }
                let path = String(line.dropFirst())
                let url = URL(fileURLWithPath: path)
                guard VideoProbe.isVideoFile(url) else { continue }
                if path.hasPrefix("/System") || path.hasPrefix("/private/var")
                    || path.hasPrefix(home + "/Library") { continue }
                guard FileManager.default.fileExists(atPath: path) else { continue }
                return url
            }
            return nil
        } catch {
            return nil
        }
    }

    nonisolated private static func fileSizeOK(_ path: String, minMB: Int) -> Bool {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        return size >= Int64(minMB) * 1024 * 1024
    }

    // MARK: - 进程工具

    nonisolated private static func processPids() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count))
        let n = proc_listallpids(&pids, count * Int32(MemoryLayout<pid_t>.size))
        return n > 0 ? Array(pids.prefix(Int(n))) : []
    }

    nonisolated private static func executablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let len = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard len > 0 else { return nil }
        return String(cString: buffer)
    }

    /// 从 `ps -p <pid> -o command=` 提取 --input-ipc-server=xxx
    nonisolated private static func argvSocket(pid: Int32) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-p", String(pid), "-o", "command="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let cmd = String(data: data, encoding: .utf8) else { return nil }
            for token in cmd.split(whereSeparator: { $0 == " " || $0 == "\n" }) {
                if token.hasPrefix("--input-ipc-server=") {
                    return String(token.dropFirst("--input-ipc-server=".count))
                }
            }
            return nil
        } catch {
            return nil
        }
    }
}
