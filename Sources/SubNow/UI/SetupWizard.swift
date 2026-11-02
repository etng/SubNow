import AppKit

/// 首次启动向导 / 组件检查窗口。
/// 纪律：单例 controller、isReleasedWhenClosed=false、Esc 可关、可反复开关。
@MainActor
final class SetupWizardController: NSWindowController, NSWindowDelegate {
    static let shared = SetupWizardController()

    private let stack = NSStackView()
    private var observerToken: UUID?
    private var lastRebuild = Date.distantPast
    private var pendingRebuild: Task<Void, Never>?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 540),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SubNow · 组件就绪检查"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        // 组件状态实时刷新（Ollama 异步探测、下载进度都会推到这里；合并节流防下载进度闪烁）
        observerToken = ComponentCenter.shared.addObserver { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.scheduleRebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func present() {
        // 先显示窗口：观察者只在可见时重建，若探测在 showWindow 前完成，
        // 完成通知会被丢弃，界面会永远停在「检测中…」。
        rebuild()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
    }

    /// 节流重建：冷却期内只安排一次尾随重建，不丢弃最终状态
    private func scheduleRebuild() {
        guard pendingRebuild == nil else { return }
        let delay = max(0, 0.5 - Date().timeIntervalSince(lastRebuild))
        pendingRebuild = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard let self, !Task.isCancelled else { return }
            self.pendingRebuild = nil
            guard self.window?.isVisible == true else { return }
            self.lastRebuild = Date()
            self.rebuild()
        }
    }

    // MARK: - UI

    private func buildContent() -> NSView {
        // 不用 NSScrollView：documentView 比 clip 矮时会被推到底部（flip 时机歧义）。
        // 组件数量有限，直接用普通容器 + 窗口可调大小。
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let title = NSTextField(labelWithString: "马上有字幕")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        stack.addArrangedSubview(title)

        let intro = NSTextField(wrappingLabelWithString: "SubNow 检测到你在用 mpv / IINA 播放缺中文字幕的视频时，会以系统通知提醒，"
            + "确认后自动生成中文字幕（先出粗稿，随后替换为精做版本）。首次使用需要就绪以下组件：")
        intro.font = .systemFont(ofSize: 12)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(intro)
        stack.setCustomSpacing(14, after: intro)

        // 只渲染当前状态：探测放在 present()，避免每次观察者重建都重新发起探测
        for id in ComponentCenter.ComponentID.allCases {
            stack.addArrangedSubview(componentRow(id))
        }

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        let hint = NSTextField(wrappingLabelWithString: "全部必需组件就绪后，SubNow 才会开始提醒可生成字幕；"
            + "此窗口可随时从菜单栏「组件就绪检查…」重新打开。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(hint)

        // 首次引导的收尾动作：打勾后重启不再自动弹窗
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.spacing = 10
        let done = NSButton(title: "完成，开始使用", target: self, action: #selector(completeSetup))
        done.bezelStyle = .rounded
        done.isEnabled = ComponentCenter.shared.isBaseReady
        footer.addArrangedSubview(done)
        let later = NSButton(title: "稍后再说", target: self, action: #selector(closeWizard))
        later.bezelStyle = .rounded
        footer.addArrangedSubview(later)
        stack.setCustomSpacing(12, after: hint)
        stack.addArrangedSubview(footer)
    }

    private func componentRow(_ id: ComponentCenter.ComponentID) -> NSView {
        let status = ComponentCenter.shared.status(id)
        let state = status?.state ?? .missing(detail: "未知")
        let required = status?.required ?? true

        var symbol = "checkmark.circle.fill"
        var color = NSColor.systemGreen
        var buttonTitle: String?
        var selector: Selector?

        switch state {
        case .ready(let detail):
            symbol = "checkmark.circle.fill"
            if id == .finalModel {
                // 精做模型是可选增强
                symbol = "checkmark.seal.fill"
                color = .systemTeal
            }
            return card(icon: symbol, tint: color, title: Self.rowTitle(id, required: required), detail: detail,
                        buttonTitle: nil, action: nil)
        case .missing(let detail):
            symbol = "arrow.down.circle"
            color = .systemOrange
            switch id {
            case .draftModel, .finalModel, .vadModel:
                buttonTitle = "下载"
                selector = #selector(downloadComponent(_:))
            case .translation:
                buttonTitle = nil  // 引导去设置（按翻译引擎类型不同处理）
            case .ffmpeg:
                buttonTitle = nil  // 引导文案
            }
            return card(icon: symbol, tint: color, title: Self.rowTitle(id, required: required),
                        detail: detail, buttonTitle: buttonTitle, action: selector, tag: id.hashValue)
        case .downloading(let progress, let detail):
            return downloadingCard(title: Self.rowTitle(id, required: required), detail: detail,
                                   progress: progress, id: id)
        case .broken(let detail):
            color = .systemRed
            switch id {
            case .draftModel, .finalModel, .vadModel:
                buttonTitle = "重新下载"
                selector = #selector(downloadComponent(_:))
            default:
                buttonTitle = nil
            }
            return card(icon: "exclamationmark.triangle.fill", tint: color,
                        title: Self.rowTitle(id, required: required), detail: detail,
                        buttonTitle: buttonTitle, action: selector, tag: id.hashValue)
        }
    }

    private static func rowTitle(_ id: ComponentCenter.ComponentID, required: Bool) -> String {
        var name = ComponentCenter.displayName(id)
        if id == .finalModel { name += "（可选，用于精做）" }
        if id == .translation { name += "（当前：\(Config.shared.translationKind.label)）" }
        return name
    }

    private func card(icon: String, tint: NSColor = .systemGreen, title: String, detail: String,
                      buttonTitle: String?, action: Selector?, tag: Int = 0) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let iconView = NSImageView(image: NSImage(systemSymbolName: icon, accessibilityDescription: nil)!
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))!)
        iconView.contentTintColor = tint

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        let d = NSTextField(wrappingLabelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor
        d.preferredMaxLayoutWidth = 380
        textStack.addArrangedSubview(t)
        textStack.addArrangedSubview(d)

        row.addArrangedSubview(iconView)
        row.addArrangedSubview(textStack)

        if let buttonTitle, let action {
            let btn = NSButton(title: buttonTitle, target: self, action: action)
            btn.bezelStyle = .rounded
            btn.controlSize = .small
            btn.tag = tag
            row.addArrangedSubview(btn)
            row.setCustomSpacing(10, after: textStack)
        }

        let holder = NSView()
        holder.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        return holder
    }

    private func downloadingCard(title: String, detail: String, progress: Double, id: ComponentCenter.ComponentID) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 10
        row.alignment = .centerY

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        let d = NSTextField(labelWithString: detail)
        d.font = .systemFont(ofSize: 11)
        d.textColor = .secondaryLabelColor

        let bar = NSProgressIndicator()
        bar.isIndeterminate = progress < 0
        if progress >= 0 { bar.doubleValue = min(max(progress, 0), 1) }
        bar.minValue = 0
        bar.maxValue = 1
        bar.frame = NSRect(x: 0, y: 0, width: 300, height: 6)
        bar.startAnimation(nil)

        textStack.addArrangedSubview(t)
        textStack.addArrangedSubview(bar)
        textStack.addArrangedSubview(d)

        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelDownloadComponent(_:)))
        cancel.bezelStyle = .rounded
        cancel.controlSize = .small
        cancel.tag = id.hashValue

        row.addArrangedSubview(textStack)
        row.addArrangedSubview(cancel)

        let holder = NSView()
        holder.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: holder.topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -4),
            row.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
            row.trailingAnchor.constraint(lessThanOrEqualTo: holder.trailingAnchor),
        ])
        return holder
    }

    // MARK: - 动作

    @objc private func downloadComponent(_ sender: NSButton) {
        guard let id = ComponentCenter.ComponentID(hashValue: sender.tag) else { return }
        ComponentCenter.shared.downloadModel(id)
    }

    @objc private func cancelDownloadComponent(_ sender: NSButton) {
        guard let id = ComponentCenter.ComponentID(hashValue: sender.tag) else { return }
        ComponentCenter.shared.cancelDownload(id)
    }

    @objc private func completeSetup() {
        Config.shared.hasCompletedSetup = true
        Log.info("首次引导完成，之后启动不再自动弹向导")
        window?.close()
    }

    @objc private func closeWizard() {
        window?.close()
    }
}

extension ComponentCenter.ComponentID {
    /// 通过 tag（hashValue）恢复枚举——组件集合小，线性查找即可
    init?(hashValue: Int) {
        for id in ComponentCenter.ComponentID.allCases where id.hashValue == hashValue {
            self = id
            return
        }
        return nil
    }

    var label: String { ComponentCenter.displayName(self) }
}

extension TranslationKind {
    var label: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAICompatible: return "OpenAI 兼容 API"
        case .appleFM: return "Apple 系统模型"
        case .none: return "不翻译"
        }
    }
}
