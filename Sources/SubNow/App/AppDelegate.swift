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
    private var ollamaIdleGeneration = 0

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
        } else if ProcessInfo.processInfo.environment["SUBNOW_SHOW_WIZARD"] == "1" {
            SetupWizardController.shared.present()
        } else if ProcessInfo.processInfo.environment["SUBNOW_SHOW_HISTORY"] == "1" {
            HistoryWindowController.shared.show()
        }

        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
        ComponentCenter.shared.addObserver { [weak self] in
            self?.updateStatusBarState()
        }

        // 通知与探测接线
        Notify.shared.actionHandler = { [weak self] in self?.handleNotifyAction($0) }
        Notify.shared.onAuthorizationChanged = { [weak self] in
            self?.updateStatusBarState()
            SettingsWindowController.shared.externalStateChanged()
        }
        Notify.shared.requestAuthorization()
        advisor.onOffer = { [weak self] offer in
            Notify.shared.postOffer(videoPath: offer.videoPath, player: offer.player)
            self?.showPlayerNotice("缺少中文字幕 · 点菜单栏 SubNow 图标生成",
                                   videoPath: offer.videoPath, socketPath: offer.socketPath)
        }
        advisor.onNotReady = { [weak self] path, reason, socketPath in
            Notify.shared.postNotReady(videoPath: path, reason: reason)
            self?.showPlayerNotice("缺少中文字幕 · SubNow 组件未就绪（点菜单栏查看）",
                                   videoPath: path, socketPath: socketPath)
        }
        monitor.onPlayback = { [weak self] snapshot in
            guard let self else { return }
            self.latestSnapshot = snapshot
            // 同卷播放时暂停音频提取，避免与播放器抢 SMB/磁盘 I/O
            PlaybackGate.shared.update(activities: snapshot.playbacks.map {
                PlaybackActivity(path: $0.videoPath, playing: $0.isPlaying)
            })
            self.updateStatusBarState()
            Task { await self.advisor.handle(snapshot) }
        }
        JobManager.shared.onJobsChanged = { [weak self] in
            self?.updateStatusBarState()
            self?.refreshOllamaIdleRelease()
        }
        monitor.start()
        updateStatusBarState()
        loadPendingRestore()
        refreshOllamaIdleRelease()
    }

    /// 任务全部停下后稍等再回收 Ollama 模型；一旦有新任务就让旧回收失效。
    /// 只在 SubNow 自己的空闲进程里判断，不停止用户管理的 ollama serve。
    private func refreshOllamaIdleRelease() {
        ollamaIdleGeneration += 1
        let generation = ollamaIdleGeneration
        guard JobManager.shared.runningJob == nil else { return }
        guard Config.shared.translationKind == .ollama else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, generation == self.ollamaIdleGeneration else { return }
            guard JobManager.shared.runningJob == nil else { return }
            await OllamaManager.shared.releaseIdleModels(baseURL: Config.shared.ollamaURL)
        }
    }

    // MARK: - 状态栏刷新

    private func updateStatusBarState() {
        guard let statusBar else { return }
        let center = ComponentCenter.shared
        let manager = JobManager.shared
        let jobs = manager.menuJobs
        let restoreCount = pendingRestore.count
        let ipcHint = latestSnapshot?.ipcStatus.hint
        let playing = latestSnapshot?.playbacks.first

        // 当前播放的视频已有未完成任务（含暂停）→ 按钮无事可做；否则允许生成
        let playingHasJob = playing.map { active in
            manager.jobs.contains {
                $0.videoPath == active.videoPath && !JobManager.isTerminal($0.stage)
            }
        } ?? false
        let canGenerate = center.isBaseReady && playing != nil && !playingHasJob
        let running = manager.runningJob
        let willPreempt = canGenerate && running != nil && running?.videoPath != playing?.videoPath

        // 任务进行中：状态行显示进度；播放区仍可用，新视频会抢占让位
        if let job = running ?? manager.activeJob {
            let stateLine: String
            switch job.stage {
            case .paused:
                stateLine = "已暂停 · \(URL(fileURLWithPath: job.videoPath).lastPathComponent)"
            case .queued:
                stateLine = "排队中 · \(URL(fileURLWithPath: job.videoPath).lastPathComponent)"
            default:
                stateLine = "\(job.stage.rawValue) \(Int(job.pct))% · \(job.detail)"
            }
            statusBar.update(stateLine: stateLine,
                             playback: playbackInfo(from: latestSnapshot),
                             canGenerate: canGenerate,
                             generateWillPreempt: willPreempt,
                             jobs: jobs, progress: running.map { $0.pct / 100 },
                             restoreCount: restoreCount, ipcHint: ipcHint)
            return
        }

        if !center.isBaseReady {
            statusBar.update(stateLine: "尚未就绪（\(center.missingSummary)）",
                             playback: nil, canGenerate: false, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
            return
        }
        if playing != nil {
            statusBar.update(stateLine: "已就绪 · 马上有字幕",
                             playback: playbackInfo(from: latestSnapshot),
                             canGenerate: canGenerate, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
        } else {
            statusBar.update(stateLine: "已就绪 · 等待播放",
                             playback: nil, canGenerate: false, jobs: jobs,
                             progress: nil, restoreCount: restoreCount, ipcHint: ipcHint)
        }
    }

    var ipcStatus: PlayerMonitor.IPCStatus? { monitor.ipcStatus }

    private func playbackInfo(from snapshot: PlayerMonitor.Snapshot?) -> PlayerMonitor.PlaybackMenuInfo? {
        guard let active = snapshot?.playbacks.first else { return nil }
        let name = URL(fileURLWithPath: active.videoPath).lastPathComponent
        let subState: String
        if let zh = active.hasChineseSubtitle {
            subState = zh ? "已有中文字幕轨" : "未加载中文字幕"
        } else {
            subState = "字幕状态检测中"
        }
        return PlayerMonitor.PlaybackMenuInfo(videoName: name, player: active.player,
                                              videoPath: active.videoPath, subtitleState: subState)
    }

    // MARK: - 通知动作

    /// 系统通知被关掉时仍要让用户看到提醒：直接画在播放器里（mpv/IINA IPC OSD）。
    /// 优先用监控刚探测到的 socket，避免 IINA 自定义路径不在候选列表里时错过。
    private func showPlayerNotice(_ text: String, videoPath: String, socketPath: String?) {
        let custom = Config.shared.customSocketPath
        DispatchQueue.global(qos: .userInitiated).async {
            if let socketPath {
                Mounter.notify(text, toVideo: videoPath, socketPath: socketPath)
            } else {
                Mounter.notify(text, forVideo: videoPath, customSocketPath: custom)
            }
        }
    }

    @objc func openNotificationSettings() {
        Notify.shared.openSystemNotificationSettings()
    }

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

    @objc func resumeJob(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        JobManager.shared.resume(videoPath: path)
        updateStatusBarState()
    }

    @objc func restorePendingJobs() {
        guard ComponentCenter.shared.isBaseReady else { showSetupWizard(); return }
        let paths = pendingRestore
        pendingRestore = []
        // 批量恢复不互相抢占，按顺序跑
        for path in paths { JobManager.shared.enqueue(videoPath: path, preempt: false) }
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
            let all = await PlayerBook.shared.queuedRestartPaths()
            // 持久化任务已直接载入队列，别再弹一次恢复提示
            let paths = all.filter { !JobManager.shared.hasActiveJob(videoPath: $0) }
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

    /// 退出前等任务收尾并确保子进程全部退出。
    /// 不用 terminateLater：它依赖嵌套 runloop 调度主队列，从 SIGTERM 的
    /// dispatch source 回调进入时清理 Task 永远排不上，进程会卡在退出中。
    /// 改为先取消退出、异步清理后再二次 terminate（此时直接放行）。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateNow }
        isTerminating = true
        Log.info("SubNow 退出，开始清理")
        monitor.stop()
        Task { @MainActor in
            await JobManager.shared.shutdown(timeout: 5)
            // 正常空闲时已回收；退出前再兜一次，避免模型拖到 keep_alive 到期
            if Config.shared.translationKind == .ollama {
                await OllamaManager.shared.releaseIdleModels(baseURL: Config.shared.ollamaURL)
            }
            await ProcessRegistry.shared.terminateAll(grace: 2)
            Log.info("清理完成")
            Log.flush()
            NSApp.terminate(nil)
        }
        return .terminateCancel
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

    @objc func showHistory() {
        HistoryWindowController.shared.show()
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
