import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBar: StatusBarController?
    private var sigtermSource: DispatchSourceSignal?
    private let monitor = PlayerMonitor()
    private let advisor = Advisor()
    private var latestSnapshot: PlayerMonitor.Snapshot?
    private var pendingRestore: [String] = []
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusBar = StatusBarController()
        installSigtermHandler()
        Log.info("菜单栏图标已就绪")

        // 首次启动 → 自动弹组件向导
        if !Config.shared.hasCompletedSetup {
            Log.info("首次启动，弹出组件向导")
            SetupWizardController.shared.present()
        } else if ProcessInfo.processInfo.environment["SUBNOW_SHOW_SETTINGS"] == "1" {
            SettingsWindowController.shared.show()
            if let tab = ProcessInfo.processInfo.environment["SUBNOW_SETTINGS_TAB"], let idx = Int(tab) {
                SettingsWindowController.shared.selectTab(idx)
            }
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
        JobManager.shared.onJobsChanged = { [weak self] in
            self?.updateStatusBarState()
        }
        monitor.start()
        updateStatusBarState()
        loadPendingRestore()
    }

    // MARK: - 状态栏刷新

    private func updateStatusBarState() {
        guard let statusBar else { return }
        let center = ComponentCenter.shared
        let manager = JobManager.shared
        let activeJob = manager.jobs.first { ![JobManager.Stage.done, .failed, .cancelled].contains($0.stage) }

        let jobs = manager.menuJobs
        let restoreCount = pendingRestore.count
        let ipcHint = latestSnapshot?.ipcStatus.hint

        // 任务进行中：状态行显示进度 + 菜单栏百分比角标
        if let job = activeJob {
            statusBar.update(stateLine: "\(job.stage.rawValue) \(Int(job.pct))% · \(job.detail)",
                             playback: playbackInfo(from: latestSnapshot, canGenerate: false),
                             canGenerate: false,
                             jobs: jobs, progress: job.pct / 100,
                             restoreCount: restoreCount, ipcHint: ipcHint)
            return
        }

        if !center.isBaseReady {
            statusBar.update(stateLine: "尚未就绪（\(center.missingSummary)）",
                             playback: nil, canGenerate: false, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
            return
        }
        if latestSnapshot?.playbacks.first != nil {
            statusBar.update(stateLine: "已就绪 · 马上有字幕",
                             playback: playbackInfo(from: latestSnapshot, canGenerate: true),
                             canGenerate: true, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
        } else {
            statusBar.update(stateLine: "已就绪 · 等待播放",
                             playback: nil, canGenerate: false, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
        }
    }

    var ipcStatus: PlayerMonitor.IPCStatus? { monitor.ipcStatus }

    private func playbackInfo(from snapshot: PlayerMonitor.Snapshot?, canGenerate: Bool) -> PlayerMonitor.PlaybackMenuInfo? {
        guard let active = snapshot?.playbacks.first else { return nil }
        let name = URL(fileURLWithPath: active.videoPath).lastPathComponent
        let subState: String
        if let zh = active.loadedChineseSubtitle {
            subState = zh ? "已有中文字幕轨" : "未加载中文字幕"
        } else {
            subState = "字幕状态检测中"
        }
        return PlayerMonitor.PlaybackMenuInfo(videoName: name, player: active.player,
                                              videoPath: active.videoPath, subtitleState: subState)
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

    /// 触发生成
    private func generateForVideo(path: String) {
        advisor.markRequested(path)
        Notify.shared.clearOffers(for: path)
        JobManager.shared.enqueue(videoPath: path)
        updateStatusBarState()
    }

    @objc func generateForCurrentPlayback() {
        guard let active = latestSnapshot?.playbacks.first else { return }
        generateForVideo(path: active.videoPath)
    }

    @objc func cancelJob(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        JobManager.shared.cancel(videoPath: path)
        updateStatusBarState()
    }

    @objc func restorePendingJobs() {
        guard ComponentCenter.shared.isBaseReady else { showSetupWizard(); return }
        let paths = pendingRestore
        pendingRestore = []
        for path in paths { JobManager.shared.enqueue(videoPath: path) }
        Log.info("恢复未完成任务：\(paths.count) 个")
        updateStatusBarState()
    }

    @objc func showAbout() {
        var credits = "编译时间：\(BuildInfo.buildTime)"
        if let commit = BuildInfo.gitCommit { credits += "\n提交：\(commit)" }
        credits += "\nwhisper.cpp v1.9.5 内嵌 · © 2026 y10n"
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "SubNow",
            .applicationVersion: BuildInfo.version,
            .version: "build \(BuildInfo.buildNumber)",
            .credits: NSAttributedString(string: credits),
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 崩溃恢复

    private func loadPendingRestore() {
        Task { @MainActor in
            let paths = await PlayerBook.shared.queuedRestartPaths()
            self.pendingRestore = paths
            if !paths.isEmpty {
                Log.info("发现 \(paths.count) 个未完成任务，等待用户从菜单恢复")
            }
            self.updateStatusBarState()
        }
    }

    // MARK: - 生命周期

    // 菜单栏应用铁律：关窗绝不退出
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 退出前等任务收尾并确保子进程全部退出；用 terminateLater 换取异步清理时间。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Log.info("SubNow 退出，开始清理")
        monitor.stop()
        Task { @MainActor in
            await JobManager.shared.shutdown(timeout: 5)
            await ProcessRegistry.shared.terminateAll(grace: 2)
            Log.info("清理完成")
            Log.flush()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
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

    @objc func showPlayerSettings() {
        SettingsWindowController.shared.show()
        SettingsWindowController.shared.selectTab(0)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
