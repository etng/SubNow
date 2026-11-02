import Foundation

/// 判定中枢：把监控快照变成行动——提示生成 / 静默记账 / 提示未就绪。
/// 防打扰纪律：
/// - 同一视频连续两轮轮询一致才评估（防瞬时打开）；
/// - 会话内每个视频最多提示一次；
/// - 记账（跨会话）由 PlayerBook 管：done/has-subs/failed/skipped 永久静默。
@MainActor
final class Advisor {
    private let book = PlayerBook.shared
    private var pendingPath: String?
    private var consecutiveCount = 0
    private var offeredThisSession = Set<String>()
    private var notReadyNotifiedThisSession = Set<String>()

    struct Offer {
        let videoPath: String
        let player: String
        let viaIPC: Bool
    }

    var onOffer: ((Offer) -> Void)?
    var onNotReady: ((String, String) -> Void)?   // (videoPath, reason)

    func handle(_ snapshot: PlayerMonitor.Snapshot) async {
        guard let active = snapshot.playbacks.first else {
            pendingPath = nil
            consecutiveCount = 0
            return
        }
        if active.videoPath != pendingPath {
            pendingPath = active.videoPath
            consecutiveCount = 1
            return
        }
        consecutiveCount += 1
        guard consecutiveCount >= 2 else { return }

        let path = active.videoPath
        guard !offeredThisSession.contains(path) else { return }

        await evaluate(playback: active)
    }

    func currentBook() -> PlayerBook { book }

    private func evaluate(playback: PlayerMonitor.Playback) async {
        let url = URL(fileURLWithPath: playback.videoPath)
        let ffprobeURL = FFmpegLocator.locateFFprobe()

        // ① 字幕缺失判定
        var needs = false
        if playback.viaIPC, let loaded = playback.loadedChineseSubtitle {
            // socket 精确判定：看"已选中"的字幕轨（用户要求：没有"加载到"合适的中文字幕才提示）
            if loaded {
                await book.set("has-subs", for: url, sidecar: true)
                return
            }
            // track-list 可读但没有已选中的中文轨 → 视为缺失
            // （文件里可能有未启用的字轨，但用户此刻确实没字幕可看）
            needs = true
        } else {
            // 无 IPC，或 IPC 连上了但 track-list 读取失败 → 降级到文件级判定
            let facts = await VideoProbe.facts(for: url, ffprobeURL: ffprobeURL)
            if !facts.needsChineseSubtitle {
                await book.set("has-subs", for: url, sidecar: facts.hasSidecar)
                return
            }
            needs = true
        }
        guard needs else { return }

        // ② 记账静默检查（跨会话）
        let sidecarNow = VideoProbe.sidecarExists(for: url).exists
        if await book.shouldSkip(video: url, sidecarExistsNow: sidecarNow) {
            return
        }

        // 用户关闭「自动通知」：照常判定/记账，但不主动弹通知；菜单手动入口仍可用
        guard Config.shared.autoAsk else { return }

        // ③ 就绪门槛：没就绪只提示一次，绝不触发流水线
        let center = ComponentCenter.shared
        if !center.isBaseReady, Config.shared.translationKind == .ollama {
            await center.ensureOllamaProbe()
        }
        if !center.isBaseReady {
            if notReadyNotifiedThisSession.insert(playback.videoPath).inserted {
                Log.info("检测到缺字幕但尚未就绪：\(playback.videoPath)（\(center.missingSummary)）")
                onNotReady?(playback.videoPath, center.missingSummary)
            }
            return
        }

        // ④ 提示（会话内一次）
        offeredThisSession.insert(playback.videoPath)
        Log.info("检测到缺中文字幕：\(playback.videoPath)（\(playback.player)，IPC=\(playback.viaIPC)）")
        onOffer?(Offer(videoPath: playback.videoPath, player: playback.player, viaIPC: playback.viaIPC))
    }

    /// 用户点了"忽略本次"→ 永久静默
    func markSkipped(_ path: String) {
        offeredThisSession.insert(path)
        let url = URL(fileURLWithPath: path)
        let sidecar = VideoProbe.sidecarExists(for: url).exists
        Task { await book.set("skipped", for: url, sidecar: sidecar) }
        Log.info("用户忽略本次：\(path)（已记入 skipped，不再提醒）")
    }

    /// 用户手动触发（菜单/通知）→ 直接交给 JobManager
    func markRequested(_ path: String) {
        offeredThisSession.insert(path)
    }

    /// 清记账（设置界面用）
    func forget(pathPrefix: String) async {
        _ = await book.forget(pathPrefix: pathPrefix)
    }
}

