import AppKit

/// 应用主菜单。LSUIElement 应用没有主菜单时，⌘Q/⌘W/Copy/Paste 全部失灵——
/// 无主菜单会导致快捷键失效，必须在启动时就挂上。
enum AppMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        // App 菜单
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "SubNow")
        let about = appMenu.addItem(withTitle: "关于 SubNow", action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        about.target = NSApp.delegate
        appMenu.addItem(.separator())
        let hide = appMenu.addItem(withTitle: "隐藏 SubNow", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hide.keyEquivalentModifierMask = .command
        let quit = appMenu.addItem(withTitle: "退出 SubNow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.keyEquivalentModifierMask = .command
        appItem.submenu = appMenu

        // Edit 菜单（文本框复制粘贴的快捷键依赖它）
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        // Window 菜单（⌘W 关窗 / ⌘M 最小化）
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = winMenu

        return main
    }
}
