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
        statusItem.button?.image = Self.menuBarImage()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    /// 定稿的「双字幕条」模板字形（scripts/make_icon.swift 生成）；缺失时退回系统符号
    private static func menuBarImage() -> NSImage? {
        for name in ["menubar-36.png", "menubar-18.png"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: nil),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return NSImage(systemSymbolName: "caption.2", accessibilityDescription: "SubNow 马上有字幕")
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

        addItem(menu, title: "组件就绪检查…", target: delegate, action: #selector(AppDelegate.showSetupWizard))
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
