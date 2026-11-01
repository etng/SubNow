import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sigtermSource: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        installSigtermHandler()
        Log.info("菜单栏图标已就绪")
    }

    /// SIGTERM → 优雅退出（保证清理逻辑与退出日志总被执行，绝不留孤儿进程）
    private func installSigtermHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.quit()
        }
        source.resume()
        sigtermSource = source
    }

    // 菜单栏应用铁律：关窗绝不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("SubNow 退出，开始清理")
        // M4：JobManager.cancelAll() + 子进程强杀在此接入
        Log.info("清理完成")
        Log.flush()
    }

    // MARK: - 动作（StatusBar 菜单项全部显式 target 到这里，杜绝 responder chain 失灵）

    @objc func showSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
