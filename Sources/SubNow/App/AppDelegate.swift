import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sigtermSource: DispatchSourceSignal?
    private let monitor = PlayerMonitor()
    private let advisor = Advisor()
    private var latestSnapshot: PlayerMonitor.Snapshot?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        installSigtermHandler()
        Log.info("菜单栏图标已就绪")

        // 首次启动 → 自动弹组件向导
        if !Config.shared.hasCompletedSetup {
            Log.info("首次启动，弹出组件向导")
            SetupWizardController.shared.present()
        }

        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
        ComponentCenter.shared.addObserver { [weak self] in
            self?.updateStatusBarState()
        }

        // 通知与探测接线
        Notify.shared.actionHandler = { [weak self] in self?.handleNotifyAction($0) }
        Notify.shared.requestAuthorization()
        advisor.onOffer = { offer in
            Notify.shared.postOffer(videoPath: offer.videoPath, player: offer.player)
        }
        advisor.onNotReady = { path, reason in
            Notify.shared.postNotReady(videoPath: path, reason: reason)
        }
        monitor.onPlayback = { [weak self] snapshot in
            guard let self else { return }
            self.latestSnapshot = snapshot
            self.updateStatusBarState()
            Task { await self.advisor.handle(snapshot) }
        }
        monitor.start()
        updateStatusBarState()
    }

    // MARK: - 状态栏刷新

    private func updateStatusBarState() {
        guard let statusBar else { return }
        let center = ComponentCenter.shared
        if !center.isBaseReady {
            statusBar.update(stateLine: "尚未就绪（\(center.missingSummary)）", playback: nil, canGenerate: false)
            return
        }
        if let active = latestSnapshot?.playbacks.first {
            let name = URL(fileURLWithPath: active.videoPath).lastPathComponent
            let subState: String
            if let zh = active.loadedChineseSubtitle {
                subState = zh ? "已有中文字幕轨" : "未加载中文字幕"
            } else {
                subState = "字幕状态检测中"
            }
            statusBar.update(stateLine: "已就绪 · 马上有字幕",
                             playback: PlayerMonitor.PlaybackMenuInfo(
                                videoName: name, player: active.player,
                                videoPath: active.videoPath, subtitleState: subState),
                             canGenerate: true)
        } else {
            statusBar.update(stateLine: "已就绪 · 等待播放", playback: nil, canGenerate: false)
        }
    }

    // MARK: - 通知动作

    private func handleNotifyAction(_ action: Notify.Action) {
        switch action {
        case .generate(let path):
            generateForVideo(path: path)
        case .skip(let path):
            advisor.markSkipped(path)
            Notify.shared.clearOffers(for: path)
        case .openSettings:
            showSetupWizard()
        }
    }

    /// 触发生成（M4 接入 JobManager）
    private func generateForVideo(path: String) {
        advisor.markRequested(path)
        Notify.shared.clearOffers(for: path)
        Log.info("请求生成字幕：\(path)")
        // M4: JobManager.shared.enqueue(videoPath:)
    }

    @objc func generateForCurrentPlayback() {
        guard let active = latestSnapshot?.playbacks.first else { return }
        generateForVideo(path: active.videoPath)
    }

    // MARK: - 生命周期

    // 菜单栏应用铁律：关窗绝不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        Log.info("SubNow 退出，开始清理")
        monitor.stop()
        // M4：JobManager.cancelAll() + 子进程强杀在此接入
        Log.info("清理完成")
        Log.flush()
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

    // MARK: - 动作（StatusBar 菜单项全部显式 target 到这里，杜绝 responder chain 失灵）

    @objc func showSettings() {
        SettingsWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSetupWizard() {
        SetupWizardController.shared.present()
    }

    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
