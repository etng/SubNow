import Foundation

/// 播放活动汇总：同一条存储卷上有视频正在播放时，音频提取应暂停，避免和播放器抢 I/O。
/// 由 AppDelegate 在每次 PlayerMonitor 轮询后更新；AudioExtractor 在后台轮询读取。
struct PlaybackActivity {
    let path: String
    /// 尽力判定：IPC 可读 pause 属性；否则用播放器是否在前台兜底。
    let playing: Bool
}

final class PlaybackGate: @unchecked Sendable {
    static let shared = PlaybackGate()

    private let lock = NSLock()
    private var activeVolumes: Set<String> = []

    /// 正在播放的卷集合。暂停中的播放器不算占用。
    func update(activities: [PlaybackActivity]) {
        var volumes = Set<String>()
        for activity in activities where activity.playing {
            if let volume = Self.volumePath(of: activity.path) {
                volumes.insert(volume)
            }
        }
        lock.lock()
        activeVolumes = volumes
        lock.unlock()
    }

    func isBusy(volumePath: String?) -> Bool {
        guard let volumePath else { return false }
        lock.lock()
        defer { lock.unlock() }
        return activeVolumes.contains(volumePath)
    }

    /// 网络盘/本地盘的卷根路径（不可达时返回 nil，调用方按“不忙”处理）。
    static func volumePath(of filePath: String) -> String? {
        let url = URL(fileURLWithPath: filePath)
        return (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
    }
}
