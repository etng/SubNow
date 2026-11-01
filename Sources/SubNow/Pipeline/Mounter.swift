import Foundation

/// 字幕挂载：谁产出谁挂载（POC 调研结果设计决策）。socket 可用且仍在播同一文件才热挂载。
@MainActor
enum Mounter {
    /// 在候选 socket 里找到"正在播这个视频"的那个
    static func resolveSocket(for videoPath: String) -> String? {
        let custom = Config.shared.customSocketPath
        var candidates: [String] = custom.isEmpty ? [] : [custom]
        candidates += Paths.socketCandidates
        for sock in candidates where MpvIPC.isPlaying(videoPath, socketPath: sock) {
            return sock
        }
        return nil
    }

    @discardableResult
    static func mount(subFile: URL, toVideo videoPath: String, title: String) -> Bool {
        guard let socketPath = resolveSocket(for: videoPath) else { return false }
        let ok = MpvIPC.subAdd(subFile.path, title: title, lang: "chi", socketPath: socketPath)
        if ok {
            Log.info("已挂载字幕轨「\(title)」→ \(videoPath)")
        }
        return ok
    }

    static func remove(title: String, fromVideo videoPath: String) {
        guard let socketPath = resolveSocket(for: videoPath) else { return }
        if MpvIPC.subRemove(byTitle: title, socketPath: socketPath) {
            Log.info("已移除字幕轨「\(title)」")
        }
    }

    static func notify(_ text: String, forVideo videoPath: String) {
        guard let socketPath = resolveSocket(for: videoPath) else { return }
        MpvIPC.showText(text, socketPath: socketPath)
    }
}
