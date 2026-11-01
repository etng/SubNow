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

    private static let categoryOffer = "SUBNOW_OFFER"
    private static let categoryNotReady = "SUBNOW_NOT_READY"

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        registerCategories()
    }

    private func registerCategories() {
        let generate = UNNotificationAction(identifier: "GENERATE", title: "生成字幕", options: [.foreground])
        let skip = UNNotificationAction(identifier: "SKIP", title: "忽略本次", options: [])
        let openSettings = UNNotificationAction(identifier: "OPEN_SETTINGS", title: "去设置", options: [.foreground])
        let offer = UNNotificationCategory(identifier: Self.categoryOffer, actions: [generate, skip], intentIdentifiers: [])
        let notReady = UNNotificationCategory(identifier: Self.categoryNotReady, actions: [openSettings], intentIdentifiers: [])
        UNUserNotificationCenter.current().setNotificationCategories([offer, notReady])
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            Log.info("通知授权: granted=\(granted) error=\(error.map(String.init(describing:)) ?? "nil")")
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
        UNUserNotificationCenter.current().add(request)
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
        UNUserNotificationCenter.current().add(request)
    }

    func postDone(videoPath: String, stage: String) {
        let content = UNMutableNotificationContent()
        content.title = "字幕已就绪 · \(stage)"
        content.body = URL(fileURLWithPath: videoPath).lastPathComponent
        content.sound = .default
        let request = UNNotificationRequest(identifier: "done-\(videoPath)-\(stage)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func clearOffers(for videoPath: String) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["offer-" + videoPath])
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["offer-" + videoPath])
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
        let path = response.notification.request.content.userInfo["path"] as? String ?? ""
        let action: Action?
        switch response.actionIdentifier {
        case "GENERATE", UNNotificationDefaultActionIdentifier:
            action = path.isEmpty ? nil : .generate(videoPath: path)
        case "SKIP":
            action = path.isEmpty ? nil : .skip(videoPath: path)
        case "OPEN_SETTINGS":
            action = .openSettings
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
