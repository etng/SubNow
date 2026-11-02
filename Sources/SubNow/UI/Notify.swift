import AppKit
import UserNotifications

/// 系统通知（非侵入提醒的唯一出口）。
/// 分类：OFFER（生成字幕/忽略本次）、NOT_READY（去设置）、DONE（完成提示）。
@MainActor
final class Notify: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notify()

    enum Action {
        case generate(videoPath: String)
        case skip(videoPath: String)
        case openSettings
    }

    var actionHandler: ((Action) -> Void)?

    /// 系统通知被用户关闭时置位：界面据此提示「改用播放器内 OSD / 去设置开启」。
    private(set) var isDenied = false
    var onAuthorizationChanged: (() -> Void)?

    private static let categoryOffer = "SUBNOW_OFFER"
    private static let categoryNotReady = "SUBNOW_NOT_READY"

    /// UNUserNotificationCenter 只在真 .app 里可用；裸二进制（swift run）与
    /// 单测进程（xctest）没有 app bundle proxy，直接调用会崩溃，这里统一降级。
    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleURL.pathExtension == "app",
              Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let generate = UNNotificationAction(identifier: "GENERATE", title: "生成字幕", options: [.foreground])
        let skip = UNNotificationAction(identifier: "SKIP", title: "忽略本次", options: [])
        let openSettings = UNNotificationAction(identifier: "OPEN_SETTINGS", title: "去设置", options: [.foreground])
        let offer = UNNotificationCategory(identifier: Self.categoryOffer, actions: [generate, skip], intentIdentifiers: [])
        let notReady = UNNotificationCategory(identifier: Self.categoryNotReady, actions: [openSettings], intentIdentifiers: [])
        center?.setNotificationCategories([offer, notReady])
    }

    func requestAuthorization() {
        guard let center else { return }
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            Log.info("通知授权: granted=\(granted) error=\(error.map(String.init(describing:)) ?? "nil")")
            Task { @MainActor in await self?.refreshAuthorization() }
        }
    }

    /// 读取当前授权状态（用户可能在我们运行期间到系统设置里改过）
    func refreshAuthorization() async {
        guard let center else { return }
        let settings = await center.notificationSettings()
        let denied = settings.authorizationStatus == .denied
        guard denied != isDenied else { return }
        isDenied = denied
        onAuthorizationChanged?()
    }

    /// 打开系统设置的「通知」面板（深链失败则退回通用通知列表）
    func openSystemNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        let candidates = [
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)",
            "x-apple.systempreferences:com.apple.preference.notifications",
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: - 提醒

    func postOffer(videoPath: String, player: String) {
        let content = UNMutableNotificationContent()
        let name = URL(fileURLWithPath: videoPath).lastPathComponent
        content.title = "《\(name)》没有中文字幕"
        content.body = "\(player) 正在播放 · 点「生成字幕」自动生成中文字幕（先出粗稿，随后替换为精做版本）"
        content.categoryIdentifier = Self.categoryOffer
        content.sound = .default
        content.userInfo = ["path": videoPath]
        let request = UNNotificationRequest(identifier: "offer-" + videoPath, content: content, trigger: nil)
        center?.add(request)
    }

    func postNotReady(videoPath: String, reason: String) {
        let content = UNMutableNotificationContent()
        let name = URL(fileURLWithPath: videoPath).lastPathComponent
        content.title = "检测到《\(name)》缺中文字幕，但 SubNow 还没准备好"
        content.body = "缺：\(reason)。去菜单栏「组件就绪检查」完成安装后即可使用。"
        content.categoryIdentifier = Self.categoryNotReady
        content.sound = nil
        content.userInfo = ["path": videoPath]
        let request = UNNotificationRequest(identifier: "notready-" + videoPath, content: content, trigger: nil)
        center?.add(request)
    }

    func postDone(videoPath: String, stage: String) {
        let content = UNMutableNotificationContent()
        content.title = "字幕已就绪 · \(stage)"
        content.body = URL(fileURLWithPath: videoPath).lastPathComponent
        content.sound = .default
        let request = UNNotificationRequest(identifier: "done-\(videoPath)-\(stage)", content: content, trigger: nil)
        center?.add(request)
    }

    func clearOffers(for videoPath: String) {
        center?.removePendingNotificationRequests(withIdentifiers: ["offer-" + videoPath])
        center?.removeDeliveredNotifications(withIdentifiers: ["offer-" + videoPath])
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // 菜单栏应用常驻后台，横幅+声音即可
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let request = response.notification.request
        let path = request.content.userInfo["path"] as? String ?? ""
        let category = request.content.categoryIdentifier
        let action: Action?
        switch response.actionIdentifier {
        case "GENERATE":
            action = path.isEmpty ? nil : .generate(videoPath: path)
        case "SKIP":
            action = path.isEmpty ? nil : .skip(videoPath: path)
        case "OPEN_SETTINGS":
            action = .openSettings
        case UNNotificationDefaultActionIdentifier:
            // 默认点击按通知类别分流：NOT_READY 只跳设置，绝不能绕过就绪门槛触发生成
            switch category {
            case Self.categoryOffer:
                action = path.isEmpty ? nil : .generate(videoPath: path)
            case Self.categoryNotReady:
                action = .openSettings
            default:
                action = nil
            }
        default:
            action = nil
        }
        if let action {
            Task { @MainActor in
                self.actionHandler?(action)
            }
        }
        completionHandler()
    }
}
