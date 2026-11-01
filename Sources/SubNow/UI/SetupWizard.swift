import AppKit

/// 首次启动向导 / 组件检查窗口。
/// 纪律：单例 controller、isReleasedWhenClosed=false、Esc 可关、可反复开关。
@MainActor
final class SetupWizardController: NSWindowController, NSWindowDelegate {
    static let shared = SetupWizardController()

    private let stack = NSStackView()
    private var migrated = false
    private var observerToken: UUID?
    private var lastRebuild = Date.distantPast

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "SubNow · 组件就绪检查"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
        // 组件状态实时刷新（Ollama 异步探测、下载进度都会推到这里；节流防下载进度闪烁）
        observerToken = ComponentCenter.shared.addObserver { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            let now = Date()
            guard now.timeIntervalSince(self.lastRebuild) >= 0.5 else { return }
            self.lastRebuild = now
            self.rebuild()
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    func present() {
        migrated = Migration.detect().needsMigration ? migrated : false
        rebuild()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    private func buildContent() -> NSView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -4),
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -28),
        ])
        return scroll
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

        // 历史守护迁移卡
        let old = Migration.detect()
        if old.needsMigration && !migrated {
            stack.addArrangedSubview(card(
                icon: "arrow.triangle.2.circlepath",
                title: "检测到历史版本 POC 调研结果 守护",
                detail: "\(old.summary)。历史版本与新版本同时跑会重复提醒，建议停用历史守护（不影响模型与已生成的字幕）。",
                buttonTitle: "停用历史守护",
                action: #selector(disableOldDaemon)
            ))
        }

        ComponentCenter.shared.refresh()
        ComponentCenter.shared.refreshOllamaAsync()
        for id in ComponentCenter.ComponentID.allCases {
            stack.addArrangedSubview(componentRow(id))
        }

        stack.setCustomSpacing(16, after: stack.arrangedSubviews.last!)
        let hint = NSTextField(wrappingLabelWithString: "全部必需组件就绪后，SubNow 才会开始提醒可生成字幕；"
            + "此窗口可随时从菜单栏「设置…」重新打开。")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(hint)
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

    @objc private func disableOldDaemon() {
        let log = Migration.migrateOldDaemon()
        migrated = true
        Log.info("迁移结果: \(log.joined(separator: "；"))")
        rebuild()
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
