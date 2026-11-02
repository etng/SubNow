import Foundation
import Darwin

/// 字幕挂载：谁产出谁挂载。socket 可用且仍在播同一文件才热挂载。
/// 所有方法都是同步 IPC，调用方应放在后台队列（流水线里通过 JobManager 的 helper 调用）。
enum Mounter {
    /// 在候选 socket 里找到"正在播这个视频"的那个
    static func resolveSocket(for videoPath: String, customSocketPath: String = "") -> String? {
        var candidates: [String] = customSocketPath.isEmpty ? [] : [customSocketPath]
        candidates += Paths.socketCandidates
        for sock in candidates where MpvIPC.isPlaying(videoPath, socketPath: sock) {
            return sock
        }
        return nil
    }

    @discardableResult
    static func mount(subFile: URL, toVideo videoPath: String, title: String,
                      customSocketPath: String = "") -> Bool {
        guard let socketPath = resolveSocket(for: videoPath, customSocketPath: customSocketPath) else {
            Log.warn("未找到正在播放的视频窗口，跳过挂载：\(videoPath)")
            return false
        }
        // 续跑/复跑时不重复挂同名字幕轨（mpv 的 sub-add 不会去重）
        if MpvIPC.trackList(socketPath: socketPath)?.contains(where: { $0.type == "sub" && $0.title == title }) == true {
            return true
        }
        let ok = MpvIPC.subAdd(subFile.path, title: title, lang: "chi", socketPath: socketPath)
        if ok {
            Log.info("已挂载字幕轨「\(title)」→ \(videoPath)")
        } else {
            Log.warn("挂载字幕轨失败「\(title)」→ \(videoPath)")
        }
        return ok
    }

    static func remove(title: String, fromVideo videoPath: String, customSocketPath: String = "") {
        guard let socketPath = resolveSocket(for: videoPath, customSocketPath: customSocketPath) else { return }
        if MpvIPC.subRemove(byTitle: title, socketPath: socketPath) {
            Log.info("已移除字幕轨「\(title)」")
        }
    }

    static func notify(_ text: String, forVideo videoPath: String, customSocketPath: String = "") {
        guard let socketPath = resolveSocket(for: videoPath, customSocketPath: customSocketPath) else { return }
        notify(text, toVideo: videoPath, socketPath: socketPath)
    }

    /// 已知 socket 时直接发送（仍校验它当前播的确实是这个视频）
    static func notify(_ text: String, toVideo videoPath: String, socketPath: String) {
        guard MpvIPC.isPlaying(videoPath, socketPath: socketPath) else { return }
        if MpvIPC.showText(text, socketPath: socketPath) {
            Log.info("播放器提示已发送：\(text)")
        } else {
            Log.warn("播放器提示发送失败：\(text)")
        }
    }
}

/// 运行中的子进程登记（退出时 terminate → 限时等待 → SIGKILL，杜绝孤儿 ffmpeg）。
final class ProcessRegistry: @unchecked Sendable {
    static let shared = ProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    func register(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func unregister(_ process: Process) {
        lock.lock(); processes.removeValue(forKey: ObjectIdentifier(process)); lock.unlock()
    }

    /// 先 SIGTERM，宽限期内没退出的再 SIGKILL。
    func terminateAll(grace: TimeInterval = 2) async {
        lock.lock()
        let running = processes.values.filter { $0.isRunning }
        lock.unlock()
        guard !running.isEmpty else { return }

        Log.info("退出清理：终止 \(running.count) 个子进程")
        for p in running { p.terminate() }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline {
            if running.allSatisfy({ !$0.isRunning }) { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        for p in running where p.isRunning {
            Log.warn("子进程 \(p.processIdentifier) 未响应 SIGTERM，强制 SIGKILL")
            kill(p.processIdentifier, SIGKILL)
        }
    }
}
