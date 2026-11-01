import AppKit

/// 菜单栏控制器。两条铁律（历史应用踩过的坑）：
/// 1) 菜单每次弹出完全重建（menuNeedsUpdate），绝不复用 NSMenuItem 实例；
/// 2) 所有可点 item 显式 target 到 AppDelegate，不依赖 responder chain。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var stateLine = "正在启动…"

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "caption.2",
                                           accessibilityDescription: "SubNow 马上有字幕")
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        _ = stateLine
    }

    func update(stateLine: String) {
        self.stateLine = stateLine
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let delegate = NSApp.delegate as? AppDelegate

        let header = NSMenuItem(title: stateLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        addItem(menu, title: "设置…", target: delegate, action: #selector(AppDelegate.showSettings))
        addItem(menu, title: "打开日志", target: delegate, action: #selector(AppDelegate.revealLog))
        menu.addItem(.separator())
        addItem(menu, title: "退出 SubNow", target: delegate, action: #selector(AppDelegate.quit), key: "q")
    }

    private func addItem(_ menu: NSMenu, title: String, target: AnyObject?, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: target != nil ? action : nil, keyEquivalent: key)
        item.target = target
        item.isEnabled = target != nil
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        menu.addItem(item)
    }
}
