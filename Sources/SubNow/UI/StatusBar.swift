import AppKit

/// 菜单栏控制器。两条铁律：
/// 1) 菜单每次弹出完全重建（menuNeedsUpdate），绝不复用 NSMenuItem 实例；
/// 2) 所有可点 item 显式 target 到 AppDelegate，不依赖 responder chain。
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private var stateLine = "正在启动…"
    private var playbackInfo: PlayerMonitor.PlaybackMenuInfo?
    private var canGenerate = false
    private var jobs: [JobManager.MenuJob] = []
    private var progress: Double?
    private var restoreCount = 0
    private var ipcHint: String?

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.image = Self.menuBarImage()
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.imageScaling = .scaleProportionallyDown
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        statusItem.isVisible = true
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        if statusItem.button == nil {
            Log.error("菜单栏状态项按钮创建失败，图标不会显示")
        }
    }

    /// 定稿的「双字幕条」模板字形（scripts/make_icon.swift 生成）。
    /// 打包产物直接读 Resources；Debug 构建没有该资源，用程序化绘制兜底，
    /// 绝不依赖可能不存在的 SF Symbol——否则状态项宽度为 0，图标彻底不可见。
    private static func menuBarImage() -> NSImage {
        if let img = bundledMenuBarImage() {
            Log.info("菜单栏图标来源：menubar PNG")
            return img
        }
        Log.warn("菜单栏 PNG 资源缺失，使用程序化字形")
        return drawnMenuBarGlyph()
    }

    private static func bundledMenuBarImage() -> NSImage? {
        for name in ["menubar-36.png", "menubar-18.png"] {
            if let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: nil),
               let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = NSSize(width: 18, height: 18)
                return img
            }
        }
        return nil
    }

    /// 与 scripts/make_icon.swift 的 drawMenuBarGlyph 同构（24 设计空间 → 18pt）
    private static func drawnMenuBarGlyph() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let s = rect.width / 24
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: 3 * s, y: 8 * s, width: 18 * s, height: 5 * s),
                         xRadius: 2.5 * s, yRadius: 2.5 * s).fill()
            NSBezierPath(roundedRect: NSRect(x: 7 * s, y: 15.5 * s, width: 10 * s, height: 4 * s),
                         xRadius: 2 * s, yRadius: 2 * s).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    func update(stateLine: String, playback: PlayerMonitor.PlaybackMenuInfo?, canGenerate: Bool,
                jobs: [JobManager.MenuJob] = [], progress: Double? = nil,
                restoreCount: Int = 0, ipcHint: String? = nil) {
        self.stateLine = stateLine
        self.playbackInfo = playback
        self.canGenerate = canGenerate
        self.jobs = jobs
        self.progress = progress
        self.restoreCount = restoreCount
        self.ipcHint = ipcHint

        // 运行中在图标旁显示百分比角标；空闲或排队（0%）时收起，避免挤占菜单栏
        if let progress, progress > 0 {
            statusItem.button?.title = "\(Int(min(progress, 1) * 100))%"
        } else {
            statusItem.button?.title = ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let delegate = NSApp.delegate as? AppDelegate

        let header = NSMenuItem(title: stateLine, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // 当前播放区
        if let info = playbackInfo, let delegate {
            let title = NSMenuItem(title: "正在播放：《\(info.videoName)》（\(info.player)）", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            let sub = NSMenuItem(title: info.subtitleState, action: nil, keyEquivalent: "")
            sub.isEnabled = false
            sub.indentationLevel = 1
            menu.addItem(sub)
            let generate = NSMenuItem(title: "为这个视频生成字幕", action: #selector(AppDelegate.generateForCurrentPlayback), keyEquivalent: "")
            generate.target = delegate
            generate.isEnabled = canGenerate
            generate.indentationLevel = 1
            menu.addItem(generate)
            menu.addItem(.separator())
        }

        // IINA 未配置 IPC 的主动提醒（点击跳到播放器设置）
        if let ipcHint, let delegate {
            addItem(menu, title: ipcHint, target: delegate, action: #selector(AppDelegate.showPlayerSettings))
            menu.addItem(.separator())
        }

        // 任务区：运行中显示进度条 + 取消入口
        if !jobs.isEmpty {
            for job in jobs {
                if job.active {
                    menu.addItem(progressItem(for: job))
                    let name = URL(fileURLWithPath: job.videoPath).lastPathComponent
                    let cancel = NSMenuItem(title: "取消「\(name)」",
                                            action: #selector(AppDelegate.cancelJob(_:)), keyEquivalent: "")
                    cancel.target = delegate
                    cancel.representedObject = job.videoPath
                    cancel.indentationLevel = 1
                    menu.addItem(cancel)
                } else {
                    let item = NSMenuItem(title: job.title, action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
        }

        if restoreCount > 0, let delegate {
            addItem(menu, title: "恢复未完成任务（\(restoreCount)）",
                    target: delegate, action: #selector(AppDelegate.restorePendingJobs))
            menu.addItem(.separator())
        }

        addItem(menu, title: "组件就绪检查…", target: delegate, action: #selector(AppDelegate.showSetupWizard))
        addItem(menu, title: "设置…", target: delegate, action: #selector(AppDelegate.showSettings))
        addItem(menu, title: "打开日志", target: delegate, action: #selector(AppDelegate.revealLog))
        menu.addItem(.separator())
        addItem(menu, title: "退出 SubNow", target: delegate, action: #selector(AppDelegate.quit), key: "q")
    }

    private func progressItem(for job: JobManager.MenuJob) -> NSMenuItem {
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 38))
        let label = NSTextField(labelWithString: job.title)
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = NSRect(x: 14, y: 18, width: 272, height: 16)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = min(max(job.pct / 100, 0), 1)
        bar.controlSize = .small
        bar.frame = NSRect(x: 14, y: 5, width: 272, height: 8)
        holder.addSubview(label)
        holder.addSubview(bar)
        let item = NSMenuItem()
        item.view = holder
        return item
    }

    private func addItem(_ menu: NSMenu, title: String, target: AnyObject?, action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: target != nil ? action : nil, keyEquivalent: key)
        item.target = target
        item.isEnabled = target != nil
        item.keyEquivalentModifierMask = key.isEmpty ? [] : .command
        menu.addItem(item)
    }
}
