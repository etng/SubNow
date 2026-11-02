import AppKit

// SubNow — 菜单栏字幕生成器
// 菜单栏常驻应用：检测 mpv/IINA 播放 → 提示生成中文字幕 → 分阶段渐进生成。

MainActor.assumeIsolated {
    Log.setup()
    Paths.ensureAll()
    Paths.installMetalResourceHint()
    Log.info("SubNow 启动 pid=\(ProcessInfo.processInfo.processIdentifier) \(BuildInfo.summary)")

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.mainMenu = AppMenu.make()  // 无主菜单则 ⌘Q/⌘W/编辑快捷键全部失效

    guard SingleInstance.acquire() else {
        SingleInstance.conflictAlertAndExit()
    }

    app.setActivationPolicy(.accessory)  // 菜单栏应用，不进 Dock
    app.run()
}
