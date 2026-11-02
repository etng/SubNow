import AppKit
import ServiceManagement

/// 翻转坐标的滚动文档视图：内容比可视区矮时也贴顶，而不是被 NSScrollView 推到底部。
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// 设置窗口：播放器 / 字幕引擎 / 翻译 / 行为 / 维护 五个分区。
/// 纪律：单例 controller、isReleasedWhenClosed=false、可反复开关、改动即时保存。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let contentHost = NSView()
    private var selectedTabIndex = 0
    private var sidebarButtons: [NSButton] = []
    private var observerToken: UUID?
    private var lastPageRebuild = Date.distantPast
    private var pendingPageRebuild: Task<Void, Never>?

    // 缓存需要在刷新间保持的控件
    private var ollamaModels: [String] = []
    private var ollamaPulls: [String: Task<Void, Never>] = [:]
    private var ollamaPullMessage = ""
    private weak var pollValueLabel: NSTextField?
    private weak var ollamaPullLabel: NSTextField?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SubNow 设置"
        window.minSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        ComponentCenter.shared.refresh()
        window.contentView = buildContent()
        ComponentCenter.shared.refreshOllamaAsync()
        observerToken = ComponentCenter.shared.addObserver { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.schedulePageRebuild()
        }
    }

    /// 合并节流：冷却期内只安排一次尾随重建，避免丢弃 Ollama 探测等最终状态
    private func schedulePageRebuild() {
        guard pendingPageRebuild == nil else { return }
        let delay = max(0, 0.5 - Date().timeIntervalSince(lastPageRebuild))
        pendingPageRebuild = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingPageRebuild = nil
            guard self.window?.isVisible == true else { return }
            self.lastPageRebuild = Date()
            self.rebuildCurrentPage()
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func show() {
        selectedTabIndex = 0
        updateSidebarSelection()
        rebuildCurrentPage()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        // 窗口可见后再探测：观察者只在可见时重建，先前完成的结果会被丢掉
        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
    }

    /// 调试用：直接切到指定分页
    func selectTab(_ index: Int) {
        selectedTabIndex = max(0, min(index, sidebarButtons.count - 1))
        updateSidebarSelection()
        rebuildCurrentPage()
    }

    // MARK: - 骨架

    private func buildContent() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .sidebar
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.translatesAutoresizingMaskIntoConstraints = false

        let sidebarStack = NSStackView()
        sidebarStack.orientation = .vertical
        sidebarStack.alignment = .leading
        sidebarStack.spacing = 4
        sidebarStack.edgeInsets = NSEdgeInsets(top: 14, left: 10, bottom: 10, right: 10)
        sidebarStack.translatesAutoresizingMaskIntoConstraints = false

        let items: [(String, String)] = [
            ("play.rectangle", "播放器"), ("cpu", "字幕引擎"), ("globe", "翻译"),
            ("slider.horizontal.3", "行为"), ("wrench.and.screwdriver", "维护"),
        ]
        sidebarButtons = items.enumerated().map { idx, item in
            let b = NSButton(title: item.1, target: self, action: #selector(sidebarClicked(_:)))
            b.image = NSImage(systemSymbolName: item.0, accessibilityDescription: nil)
            b.imagePosition = .imageLeading
            b.isBordered = false
            b.setButtonType(.momentaryPushIn)
            b.tag = idx
            b.wantsLayer = true
            b.layer?.cornerRadius = 6
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 30).isActive = true
            return b
        }
        sidebarButtons.forEach { sidebarStack.addArrangedSubview($0) }
        // 加入层级后才能激活跨视图宽度约束
        for b in sidebarButtons {
            b.widthAnchor.constraint(equalTo: sidebarStack.widthAnchor, constant: -20).isActive = true
        }

        contentHost.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(effect)
        effect.addSubview(sidebarStack)
        container.addSubview(divider)
        container.addSubview(contentHost)

        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: container.topAnchor),
            effect.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            effect.widthAnchor.constraint(equalToConstant: 182),
            sidebarStack.topAnchor.constraint(equalTo: effect.topAnchor),
            sidebarStack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            sidebarStack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            sidebarStack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),

            divider.leadingAnchor.constraint(equalTo: effect.trailingAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.topAnchor.constraint(equalTo: container.topAnchor),
            divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            contentHost.leadingAnchor.constraint(equalTo: effect.trailingAnchor, constant: 28),
            contentHost.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -28),
            contentHost.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            contentHost.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -16),
        ])
        updateSidebarSelection()
        rebuildCurrentPage()
        return container
    }

    @objc private func sidebarClicked(_ sender: NSButton) {
        selectedTabIndex = sender.tag
        updateSidebarSelection()
        rebuildCurrentPage()
    }

    private func updateSidebarSelection() {
        for (idx, b) in sidebarButtons.enumerated() {
            let selected = idx == selectedTabIndex
            b.layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.16).cgColor
                : NSColor.clear.cgColor
            let style = NSMutableParagraphStyle()
            style.alignment = .left
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .foregroundColor: selected ? NSColor.controlAccentColor : NSColor.labelColor,
                .font: NSFont.systemFont(ofSize: 13, weight: selected ? .semibold : .regular),
                .paragraphStyle: style,
            ])
            b.contentTintColor = selected ? .controlAccentColor : .secondaryLabelColor
        }
    }

    private func rebuildCurrentPage() {
        // 每次重建当前页——保证组件状态/配置值总是最新（页面视图不缓存）
        contentHost.subviews.forEach { $0.removeFromSuperview() }
        let builders: [() -> NSView] = [playersPage, enginePage, translationPage, behaviorPage, maintenancePage]
        let idx = max(0, min(selectedTabIndex, builders.count - 1))
        let page = builders[idx]()

        // 页面放进滚动容器：窗口可缩放，内容超高时不会被裁切
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let document = FlippedDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        page.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(page)
        scroll.documentView = document
        contentHost.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: contentHost.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: contentHost.bottomAnchor),

            page.topAnchor.constraint(equalTo: document.topAnchor),
            page.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            page.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -16),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
    }

    // MARK: - 通用构件

    private func section(_ title: String) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        let holder = NSView()
        holder.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: holder.topAnchor),
            label.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        return holder
    }

    private func note(_ text: String, width: CGFloat = 600) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        return label
    }

    private func row(_ title: String, _ control: NSView, hint: String? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)

        let pair = NSStackView(views: [label, control])
        pair.orientation = .horizontal
        pair.alignment = .centerY
        pair.spacing = 14

        if let hint {
            let h = note(hint, width: 480)
            let v = NSStackView(views: [pair, h])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 5
            return v
        }
        return pair
    }

    private func statusLine(_ id: ComponentCenter.ComponentID) -> NSView {
        let status = ComponentCenter.shared.status(id)
        var icon = "checkmark.circle.fill"
        var tint = NSColor.systemGreen
        var text = ""
        if let state = status?.state {
            switch state {
            case .ready(let detail):
                text = detail
                if id == .finalModel { icon = "checkmark.seal.fill"; tint = .systemTeal }
            case .missing(let detail):
                icon = "arrow.down.circle"; tint = .systemOrange; text = detail
            case .downloading(let progress, let detail):
                icon = "arrow.down.circle.fill"; tint = .systemBlue
                text = progress >= 0 ? "\(detail)（\(Int(progress * 100))%）" : detail
            case .broken(let detail):
                icon = "exclamationmark.triangle.fill"; tint = .systemRed
                text = detail
            }
        } else {
            icon = "questionmark.circle"; tint = .systemGray; text = "未探测"
        }

        let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))!)
        iconView.contentTintColor = tint
        let label = NSTextField(labelWithString: ComponentCenter.displayName(id))
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let detail = NSTextField(labelWithString: text)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [iconView, label, detail])
        stack.orientation = .horizontal
        stack.alignment = .firstBaseline
        stack.spacing = 8
        detail.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        return stack
    }

    private func componentRow(_ id: ComponentCenter.ComponentID, downloadable: Bool) -> NSView {
        let line = statusLine(id)
        guard downloadable else { return line }
        let st = ComponentCenter.shared.status(id)
        var ready = false
        if case .ready = st?.state { ready = true }
        var downloading = ComponentCenter.shared.isDownloading(id)

        let button: NSButton
        if downloading {
            button = NSButton(title: "取消", target: self, action: #selector(cancelDownload(_:)))
        } else {
            button = NSButton(title: ready ? "重新下载" : "下载", target: self, action: #selector(downloadComponent(_:)))
        }
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.tag = id.hashValue
        let wrap = NSStackView(views: [line, button])
        wrap.orientation = .horizontal
        wrap.spacing = 12
        wrap.alignment = .centerY
        return wrap
    }

    @objc private func downloadComponent(_ sender: NSButton) {
        guard let id = ComponentCenter.ComponentID(hashValue: sender.tag) else { return }
        ComponentCenter.shared.downloadModel(id)
    }

    @objc private func cancelDownload(_ sender: NSButton) {
        guard let id = ComponentCenter.ComponentID(hashValue: sender.tag) else { return }
        ComponentCenter.shared.cancelDownload(id)
    }

    // MARK: - ① 播放器

    private func playersPage() -> NSView {
        let cfg = Config.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(section("检测"))
        let pollLabel = NSTextField(labelWithString: "\(Int(cfg.pollSeconds)) 秒")
        pollLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        pollLabel.textColor = .secondaryLabelColor
        self.pollValueLabel = pollLabel
        let poll = NSSlider(value: cfg.pollSeconds, minValue: 1, maxValue: 10, target: self, action: #selector(pollChanged(_:)))
        poll.frame = NSRect(x: 0, y: 0, width: 220, height: 20)
        let pollStack = NSStackView(views: [poll, pollLabel])
        pollStack.orientation = .horizontal
        pollStack.spacing = 8
        stack.addArrangedSubview(row("检测间隔", pollStack))
        stack.addArrangedSubview(note("检测越频繁反应越快，也越耗电；默认 3 秒已足够灵敏。", width: 470))

        let minField = NSTextField(string: String(cfg.minFileMB))
        minField.frame = NSRect(x: 0, y: 0, width: 70, height: 22)
        minField.target = self
        minField.action = #selector(minMBChanged(_:))
        stack.addArrangedSubview(row("最小文件体积 (MB)", minField,
                                     hint: "小于该体积的文件不触发（过滤广告/片段）。"))

        let sockField = NSTextField(string: cfg.customSocketPath)
        sockField.placeholderString = "留空使用默认候选"
        sockField.frame = NSRect(x: 0, y: 0, width: 250, height: 22)
        sockField.target = self
        sockField.action = #selector(socketChanged(_:))
        stack.addArrangedSubview(row("自定义连接路径", sockField,
                                     hint: "留空使用默认路径 /tmp/subnow-mpv.sock；也可以填写自己的路径。"))

        stack.addArrangedSubview(section("IINA 联动（字幕自动挂载）"))
        stack.addArrangedSubview(note(
            "IINA 默认不允许外部程序联动。开启方法：IINA → ⌘, 设置 → 高级 → 勾选「启用高级设置」→ "
            + "「额外 mpv 选项」添加一项：名称 input-ipc-server，值 /tmp/subnow-mpv.sock → 完全退出 IINA 重开。\n"
            + "未开启也能用（字幕生成在视频旁，重开自动加载；但不能自动挂载、判定精度略低）——当前状态：\(ipcStateDescription())。", width: 470))

        let verify = NSButton(title: "验证连接", target: self, action: #selector(verifyIPC))
        verify.bezelStyle = .rounded
        verify.controlSize = .small
        stack.addArrangedSubview(row("", verify))

        stack.addArrangedSubview(section("mpv（可选）"))
        let copyMpv = NSButton(title: "复制 mpv.conf 建议行", target: self, action: #selector(copyMpvConf))
        copyMpv.bezelStyle = .rounded
        copyMpv.controlSize = .small
        stack.addArrangedSubview(note("命令行 mpv 需在 ~/.config/mpv/mpv.conf 中加入对应行：", width: 470))
        stack.addArrangedSubview(copyMpv)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        return stack
    }

    private func ipcStateDescription() -> String {
        guard let status = (NSApp.delegate as? AppDelegate)?.ipcStatus else {
            return "尚未轮询（等待播放器监控完成首轮）"
        }
        switch status {
        case .noPlayer:
            return "未检测到正在运行的 IINA 或 mpv"
        case .connected(let socket):
            return "已连接（\(socket)）"
        case .notConfigured(let player):
            return "\(player) 正在运行，尚未开启联动"
        case .failed(let socket, let reason):
            return "连接失败（\(socket)）：\(reason)"
        }
    }

    // MARK: - ② 字幕引擎

    private func enginePage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(section("语音识别引擎"))
        stack.addArrangedSubview(statusLineText("whisper.cpp v1.9.5 · Metal 加速 · 内嵌于应用（无需安装）"))

        stack.addArrangedSubview(section("模型（自动下载，支持国内镜像）"))
        let dirField = NSTextField(string: Config.shared.modelsDir.path)
        dirField.frame = NSRect(x: 0, y: 0, width: 300, height: 22)
        dirField.target = self
        dirField.action = #selector(modelsDirChanged(_:))
        stack.addArrangedSubview(row("模型目录", dirField))

        stack.addArrangedSubview(componentRow(.draftModel, downloadable: true))
        stack.addArrangedSubview(componentRow(.vadModel, downloadable: true))
        stack.addArrangedSubview(componentRow(.finalModel, downloadable: true))
        stack.addArrangedSubview(note("草稿模型 + VAD 为必需；精做模型可选（缺失时自动跳过精做阶段）。", width: 470))

        stack.addArrangedSubview(section("音频提取"))
        stack.addArrangedSubview(componentRow(.ffmpeg, downloadable: false))
        let copyFF = NSButton(title: "复制 brew 安装命令", target: self, action: #selector(copyBrewFFmpeg))
        copyFF.bezelStyle = .rounded
        copyFF.controlSize = .small
        stack.addArrangedSubview(copyFF)

        return stack
    }

    private func statusLineText(_ text: String) -> NSView {
        let iconView = NSImageView(image: NSImage(systemSymbolName: "checkmark.circle.fill",
                                                   accessibilityDescription: nil)!)
        iconView.contentTintColor = .systemGreen
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        return NSStackView(views: [iconView, label])
    }

    // MARK: - ③ 翻译

    private func translationPage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        let cfg = Config.shared

        stack.addArrangedSubview(section("翻译引擎"))
        let seg = NSSegmentedControl(labels: ["Ollama（本地）", "OpenAI 兼容 API", "Apple 系统模型", "不翻译（仅原文）"],
                                     trackingMode: .selectOne, target: self, action: #selector(translationKindChanged(_:)))
        seg.selectedSegment = [
            TranslationKind.ollama: 0, .openAICompatible: 1, .appleFM: 2, .none: 3
        ][cfg.translationKind] ?? 0
        stack.addArrangedSubview(seg)
        stack.addArrangedSubview(note("切换后立即保存；正在生成的任务不受影响，新任务生效。", width: 470))

        switch cfg.translationKind {
        case .ollama:
            let urlField = NSTextField(string: cfg.ollamaURL)
            urlField.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            urlField.target = self
            urlField.action = #selector(ollamaURLChanged(_:))
            stack.addArrangedSubview(row("Ollama 地址", urlField))

            let detect = NSButton(title: "检测服务并列出模型", target: self, action: #selector(detectOllama))
            detect.bezelStyle = .rounded
            detect.controlSize = .small
            stack.addArrangedSubview(detect)

            let draftPopup = NSPopUpButton()
            draftPopup.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            fillModelPopup(draftPopup, selected: cfg.ollamaDraftModel)
            draftPopup.target = self
            draftPopup.action = #selector(draftModelPicked(_:))
            let draftPull = NSButton(title: ollamaPulls[cfg.ollamaDraftModel] != nil ? "取消" : "拉取",
                                     target: self, action: #selector(pullOllamaDraft(_:)))
            draftPull.bezelStyle = .rounded
            draftPull.controlSize = .small
            let draftRow = NSStackView(views: [draftPopup, draftPull])
            draftRow.orientation = .horizontal
            draftRow.spacing = 8
            stack.addArrangedSubview(row("草稿翻译模型", draftRow, hint: "用于粗稿阶段；qwen2.5:7b 起步即可。"))

            let finalPopup = NSPopUpButton()
            finalPopup.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
            fillModelPopup(finalPopup, selected: cfg.ollamaFinalModel)
            finalPopup.target = self
            finalPopup.action = #selector(finalModelPicked(_:))
            let finalPull = NSButton(title: ollamaPulls[cfg.ollamaFinalModel] != nil ? "取消" : "拉取",
                                     target: self, action: #selector(pullOllamaFinal(_:)))
            finalPull.bezelStyle = .rounded
            finalPull.controlSize = .small
            let finalRow = NSStackView(views: [finalPopup, finalPull])
            finalRow.orientation = .horizontal
            finalRow.spacing = 8
            stack.addArrangedSubview(row("精做翻译模型", finalRow, hint: "用于精做阶段；越大越慢越准。"))

            let pullLabel = NSTextField(labelWithString: ollamaPullMessage)
            pullLabel.font = .systemFont(ofSize: 11)
            pullLabel.textColor = .secondaryLabelColor
            pullLabel.lineBreakMode = .byTruncatingMiddle
            pullLabel.isHidden = ollamaPullMessage.isEmpty
            self.ollamaPullLabel = pullLabel
            stack.addArrangedSubview(pullLabel)

        case .openAICompatible:
            let apiURL = NSTextField(string: cfg.openAIBaseURL)
            apiURL.placeholderString = "https://api.example.com/v1"
            apiURL.frame = NSRect(x: 0, y: 0, width: 250, height: 22)
            apiURL.target = self
            apiURL.action = #selector(openAIURLChanged(_:))
            stack.addArrangedSubview(row("API Base URL", apiURL))

            let apiKey = NSSecureTextField(string: cfg.openAIAPIKey)
            apiKey.placeholderString = "sk-…"
            apiKey.frame = NSRect(x: 0, y: 0, width: 250, height: 22)
            apiKey.target = self
            apiKey.action = #selector(openAIKeyChanged(_:))
            stack.addArrangedSubview(row("API Key", apiKey))

            let apiModel = NSTextField(string: cfg.openAIModel)
            apiModel.placeholderString = "模型名"
            apiModel.frame = NSRect(x: 0, y: 0, width: 250, height: 22)
            apiModel.target = self
            apiModel.action = #selector(openAIModelChanged(_:))
            stack.addArrangedSubview(row("模型名", apiModel))

        case .appleFM:
            if let fm = AppleFMAvailability.describe() {
                stack.addArrangedSubview(statusLineText(fm))
            } else {
                stack.addArrangedSubview(note("Apple 系统模型：\(AppleFMAvailability.unavailableReason)。", width: 470))
            }

        case .none:
            stack.addArrangedSubview(note("不翻译：只输出原文转录（SRT/ASS），跳过双语与精做翻译阶段。", width: 470))
        }
        return stack
    }

    private func fillModelPopup(_ popup: NSPopUpButton, selected: String) {
        popup.removeAllItems()
        var models = ollamaModels
        if !models.contains(selected) { models.append(selected) }
        popup.addItems(withTitles: models)
        popup.selectItem(withTitle: selected)
    }

    // MARK: - ④ 行为

    private func behaviorPage() -> NSView {
        let cfg = Config.shared
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(section("提醒"))
        stack.addArrangedSubview(check("检测到缺中文字幕时弹系统通知", cfg.autoAsk, #selector(autoAskChanged),
                                       hint: "关闭后不再主动弹通知，只在菜单栏保留「为这个视频生成字幕」入口。"))
        stack.addArrangedSubview(section("流水线"))
        stack.addArrangedSubview(check("粗稿完成后自动精做", cfg.autoFinal,
                                       #selector(autoFinalChanged),
                                       hint: "精做会重新转录并加强翻译，质量更高、耗时更长；关闭则生成粗稿即止。"))

        let langPopup = NSPopUpButton()
        let langs: [(String, String)] = [("自动检测", "auto"), ("日本語", "ja"), ("English", "en"),
                                         ("한국어", "ko"), ("Deutsch", "de"), ("Français", "fr"), ("Русский", "ru"), ("Español", "es")]
        for (title, code) in langs { langPopup.addItem(withTitle: title); langPopup.lastItem?.representedObject = code }
        let langIdx = langs.firstIndex { $0.1 == cfg.language } ?? 0
        langPopup.selectItem(at: langIdx)
        langPopup.target = self
        langPopup.action = #selector(languagePicked(_:))
        stack.addArrangedSubview(row("语音语言", langPopup, hint: "一般保持自动检测；固定语言可减少误判。"))

        let lineLen = NSTextField(string: String(cfg.lineLen))
        lineLen.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        lineLen.target = self
        lineLen.action = #selector(lineLenChanged(_:))
        stack.addArrangedSubview(row("每行译文字数", lineLen, hint: "实践经验 20 最舒适；影响分行与翻译提示词。"))

        let batch = NSTextField(string: String(cfg.batchSize))
        batch.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        batch.target = self
        batch.action = #selector(batchChanged(_:))
        stack.addArrangedSubview(row("翻译批大小（行）", batch, hint: "默认 30 行/批。"))

        let conc = NSTextField(string: String(cfg.maxConcurrent))
        conc.frame = NSRect(x: 0, y: 0, width: 60, height: 22)
        conc.target = self
        conc.action = #selector(concurrencyChanged(_:))
        stack.addArrangedSubview(row("同时任务数", conc, hint: "转录吃满 GPU，多任务并不更快；默认 1。"))
        return stack
    }

    private func check(_ title: String, _ value: Bool, _ action: Selector, hint: String? = nil) -> NSView {
        let box = NSButton(checkboxWithTitle: title, target: self, action: action)
        box.state = value ? .on : .off
        box.font = .systemFont(ofSize: 13)
        if let hint {
            let v = NSStackView(views: [box, note(hint, width: 520)])
            v.orientation = .vertical
            v.alignment = .leading
            v.spacing = 2
            return v
        }
        return box
    }

    // MARK: - ⑤ 维护

    private func maintenancePage() -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16

        stack.addArrangedSubview(section("通用"))
        let launch = NSButton(checkboxWithTitle: "登录时自动启动 SubNow", target: self, action: #selector(launchAtLoginChanged))
        launch.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        stack.addArrangedSubview(launch)

        stack.addArrangedSubview(section("忽略记录"))
        stack.addArrangedSubview(note("被「忽略本次」、已生成或已判定有字幕的视频会被永久记住，不再重复提醒；"
            + "字幕文件被删除后会自动重新判定。", width: 470))
        let bookView = NSTextField(wrappingLabelWithString: "读取中…")
        bookView.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        bookView.preferredMaxLayoutWidth = 580
        stack.addArrangedSubview(bookView)
        Task { @MainActor [weak self, weak bookView] in
            let records = await PlayerBook.shared.allRecords()
            var lines = records.prefix(30).map { _, r in
                "[\(r.status)] \(URL(fileURLWithPath: r.path).lastPathComponent)"
            }
            if records.count > 30 { lines.append("… 共 \(records.count) 条") }
            bookView?.stringValue = lines.isEmpty ? "（暂无记录）" : lines.joined(separator: "\n")
            self?.viewNeedsLayout()
        }

        let clearAll = NSButton(title: "清除全部记录（重新提醒）", target: self, action: #selector(forgetAll))
        clearAll.bezelStyle = .rounded
        clearAll.controlSize = .small
        stack.addArrangedSubview(clearAll)

        stack.addArrangedSubview(section("诊断"))
        let buttons = NSStackView(views: [
            { let b = NSButton(title: "运行自检", target: self, action: #selector(runSelfCheck)); b.bezelStyle = .rounded; b.controlSize = .small; return b }(),
            { let b = NSButton(title: "打开日志", target: self, action: #selector(revealLog)); b.bezelStyle = .rounded; b.controlSize = .small; return b }(),
            { let b = NSButton(title: "打开组件就绪检查", target: self, action: #selector(openWizard)); b.bezelStyle = .rounded; b.controlSize = .small; return b }(),
        ])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        stack.addArrangedSubview(buttons)

        stack.addArrangedSubview(section("关于"))
        stack.addArrangedSubview(note("\(BuildInfo.summary)\nwhisper.cpp v1.9.5 内嵌", width: 580))
        return stack
    }

    fileprivate func viewNeedsLayout() {
        window?.contentView?.needsLayout = true
    }

    // MARK: - 动作

    @objc private func pollChanged(_ sender: NSSlider) {
        Config.shared.pollSeconds = sender.doubleValue
        pollValueLabel?.stringValue = "\(Int(sender.doubleValue)) 秒"
        Log.info("检测间隔调整为 \(Int(sender.doubleValue))s（下轮生效）")
    }

    @objc private func minMBChanged(_ sender: NSTextField) {
        Config.shared.minFileMB = max(0, sender.integerValue)
    }

    @objc private func socketChanged(_ sender: NSTextField) {
        Config.shared.customSocketPath = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func verifyIPC() {
        let candidates = [Config.shared.customSocketPath].filter { !$0.isEmpty } + Paths.socketCandidates
        let alertTitle = "连接测试"
        Task { @MainActor in
            let report = await Task.detached(priority: .userInitiated) { () -> String in
                var lines: [String] = []
                for sock in candidates {
                    guard FileManager.default.fileExists(atPath: sock) else {
                        lines.append("✗ \(sock)：不存在")
                        continue
                    }
                    if let path = MpvIPC.currentPath(socketPath: sock) {
                        lines.append("✓ \(sock)：连接成功，正在播放 \(path)")
                    } else {
                        lines.append("✗ \(sock)：连接文件存在但读取失败（播放器未就绪、无权限或进程已退出）")
                    }
                }
                return lines.joined(separator: "\n")
            }.value
            let alert = NSAlert()
            alert.messageText = alertTitle
            alert.informativeText = report.isEmpty ? "没有可测试的连接路径。" : report
            alert.runModal()
        }
    }

    @objc private func copyMpvConf() {
        let line = "input-ipc-server=/tmp/subnow-mpv.sock"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line, forType: .string)
    }

    @objc private func copyBrewFFmpeg() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("brew install ffmpeg", forType: .string)
    }

    @objc private func modelsDirChanged(_ sender: NSTextField) {
        let url = URL(fileURLWithPath: sender.stringValue)
        Config.shared.modelsDir = url
        ComponentCenter.shared.refresh()
    }

    @objc private func translationKindChanged(_ sender: NSSegmentedControl) {
        let kinds: [TranslationKind] = [.ollama, .openAICompatible, .appleFM, .none]
        Config.shared.translationKind = kinds[max(0, min(sender.selectedSegment, 3))]
        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
        // 只显示当前引擎的配置项；切换后立即重绘，不能等异步观察者
        rebuildCurrentPage()
    }

    @objc private func ollamaURLChanged(_ sender: NSTextField) {
        Config.shared.ollamaURL = sender.stringValue.trimmingCharacters(in: .whitespaces)
        ComponentCenter.shared.refreshOllamaAsync()
    }

    @objc private func detectOllama() {
        Task { @MainActor in
            do {
                let models = try await OllamaManager.shared.listModels(baseURL: Config.shared.ollamaURL)
                self.ollamaModels = models
                ComponentCenter.shared.refreshOllamaAsync()
                self.rebuildCurrentPage()
                let alert = NSAlert()
                alert.messageText = "Ollama 在线"
                alert.informativeText = "已安装模型：\n" + models.joined(separator: "\n")
                alert.runModal()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Ollama 不可达"
                alert.informativeText = error.localizedDescription
                    + "\n\n启动方法：打开 Ollama.app，或终端运行 ollama serve"
                alert.runModal()
            }
        }
    }

    @objc private func draftModelPicked(_ sender: NSPopUpButton) {
        Config.shared.ollamaDraftModel = sender.titleOfSelectedItem ?? Config.shared.ollamaDraftModel
        ComponentCenter.shared.refreshOllamaAsync()
    }

    @objc private func finalModelPicked(_ sender: NSPopUpButton) {
        Config.shared.ollamaFinalModel = sender.titleOfSelectedItem ?? Config.shared.ollamaFinalModel
        ComponentCenter.shared.refreshOllamaAsync()
    }

    @objc private func pullOllamaDraft(_ sender: NSButton) {
        pullOllama(Config.shared.ollamaDraftModel)
    }

    @objc private func pullOllamaFinal(_ sender: NSButton) {
        pullOllama(Config.shared.ollamaFinalModel)
    }

    private func pullOllama(_ model: String) {
        let name = model.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let running = ollamaPulls[name] {
            running.cancel()
            return
        }
        ollamaPullMessage = "准备拉取 \(name)…"
        let task = Task { @MainActor in
            defer {
                ollamaPulls[name] = nil
                if Task.isCancelled { ollamaPullMessage = "已取消拉取 \(name)" }
                rebuildCurrentPage()
            }
            do {
                let stream = try await OllamaManager.shared.pull(baseURL: Config.shared.ollamaURL, model: name)
                for await event in stream {
                    if Task.isCancelled { return }
                    switch event {
                    case .progress(let fraction, let status):
                        ollamaPullMessage = fraction >= 0
                            ? "\(status)（\(Int(fraction * 100))%）"
                            : status
                        ollamaPullLabel?.stringValue = ollamaPullMessage
                        ollamaPullLabel?.isHidden = false
                    case .done:
                        ollamaPullMessage = "\(name) 拉取完成"
                        ollamaModels = (try? await OllamaManager.shared.listModels(baseURL: Config.shared.ollamaURL)) ?? ollamaModels
                        ComponentCenter.shared.refreshOllamaAsync()
                    case .failed(let message):
                        ollamaPullMessage = "\(name) 拉取失败：\(message)"
                    }
                }
            } catch {
                ollamaPullMessage = "\(name) 拉取失败：\(error.localizedDescription)"
            }
        }
        ollamaPulls[name] = task
        rebuildCurrentPage()
    }

    @objc private func openAIURLChanged(_ sender: NSTextField) {
        Config.shared.openAIBaseURL = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func openAIKeyChanged(_ sender: NSSecureTextField) {
        Config.shared.openAIAPIKey = sender.stringValue
    }

    @objc private func openAIModelChanged(_ sender: NSTextField) {
        Config.shared.openAIModel = sender.stringValue.trimmingCharacters(in: .whitespaces)
    }

    @objc private func autoAskChanged(_ sender: NSButton) {
        Config.shared.autoAsk = sender.state == .on
    }

    @objc private func autoFinalChanged(_ sender: NSButton) {
        Config.shared.autoFinal = sender.state == .on
    }

    @objc private func languagePicked(_ sender: NSPopUpButton) {
        Config.shared.language = sender.selectedItem?.representedObject as? String ?? "auto"
    }

    @objc private func lineLenChanged(_ sender: NSTextField) {
        Config.shared.lineLen = min(40, max(8, sender.integerValue))
    }

    @objc private func batchChanged(_ sender: NSTextField) {
        Config.shared.batchSize = min(100, max(5, sender.integerValue))
    }

    @objc private func concurrencyChanged(_ sender: NSTextField) {
        Config.shared.maxConcurrent = min(3, max(1, sender.integerValue))
    }

    @objc private func launchAtLoginChanged(_ sender: NSButton) {
        guard Bundle.main.bundleIdentifier != nil else {
            let alert = NSAlert()
            alert.messageText = "仅打包后的 .app 支持开机自启"
            alert.informativeText = "当前是开发模式（swift run），跳过注册。"
            alert.runModal()
            sender.state = .off
            return
        }
        do {
            if sender.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("开机自启设置失败: \(error.localizedDescription)")
            sender.state = sender.state == .on ? .off : .on
        }
    }

    @objc private func forgetAll() {
        Task {
            await PlayerBook.shared.forget(pathPrefix: "all")
            rebuildCurrentPage()
        }
    }

    @objc private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.logFile])
    }

    @objc private func openWizard() {
        SetupWizardController.shared.present()
    }

    @objc private func runSelfCheck() {
        Task { @MainActor in
            ComponentCenter.shared.refresh()
            ComponentCenter.shared.refreshOllamaAsync()
            let center = ComponentCenter.shared
            let componentLine = center.isBaseReady
                ? "✓ 组件就绪（\(center.missingSummary.isEmpty ? "全部必需项齐备" : center.missingSummary)）"
                : "✗ 未就绪：\(center.missingSummary)"
            let ipcLine = "播放器联动：\(ipcStateDescription())"
            let kind = Config.shared.translationKind
            let draftModel = Config.shared.draftModelURL
            let vadModel = Config.shared.vadModelURL

            // 引擎冒烟会加载 GB 级模型并跑 Metal，必须离开主线程
            let engineLine = await Task.detached(priority: .userInitiated) { () -> String in
                let silent = FileManager.default.temporaryDirectory
                    .appendingPathComponent("subnow-check-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: silent) }
                do {
                    try Self.silentWavData(seconds: 1).write(to: silent)
                    let engine = try WhisperEngine(modelURL: draftModel, vadURL: vadModel)
                    let t0 = Date()
                    let result = try engine.run(wavURL: silent, language: "auto",
                                                progress: { _ in }, isCancelled: { false })
                    return "✓ 引擎冒烟通过（Metal 转录 \(String(format: "%.2f", -t0.timeIntervalSinceNow))s，语言=\(result.language)，分段=\(result.segments.count)）"
                } catch {
                    return "✗ 引擎冒烟失败：\(error.localizedDescription)"
                }
            }.value

            var lines = [componentLine, engineLine]

            // Ollama（URLSession 异步，不阻塞主线程）
            if kind == .ollama {
                let models = (try? await OllamaManager.shared.listModels(baseURL: Config.shared.ollamaURL)) ?? []
                lines.append(models.isEmpty ? "✗ Ollama 不可达（\(Config.shared.ollamaURL)）"
                                            : "✓ Ollama 在线（\(models.count) 个模型）")
            }

            lines.append(ipcLine)

            let alert = NSAlert()
            alert.messageText = "SubNow 自检"
            alert.informativeText = lines.joined(separator: "\n")
            alert.alertStyle = lines.contains(where: { $0.hasPrefix("✗") }) ? .warning : .informational
            alert.runModal()
        }
    }

    /// 生成合法的 16kHz 单声道 PCM16 WAV（全静音），供引擎冒烟使用。
    nonisolated private static func silentWavData(seconds: Double, sampleRate: Int = 16000) -> Data {
        let frames = Int(seconds * Double(sampleRate))
        var data = Data(capacity: 44 + frames * 2)
        func str(_ s: String) { data.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { data.append(contentsOf: $0) } }
        str("RIFF"); u32(UInt32(36 + frames * 2)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        str("data"); u32(UInt32(frames * 2))
        data.append(Data(repeating: 0, count: frames * 2))
        return data
    }
}
