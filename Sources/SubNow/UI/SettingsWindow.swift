import AppKit

/// 设置窗口。三个严肃性要点：
/// 1) 单例 controller，关闭只是 orderOut，绝不重复开窗；
/// 2) window.isReleasedWhenClosed = false（历史应用「关不掉/再开崩溃」的直接根因）；
/// 3) 内容后续里程碑逐步填充（组件管理/翻译/行为）。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let versionLabel = NSTextField(labelWithString: "")

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SubNow 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = buildContent()
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    private func buildContent() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 14
        container.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        container.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "马上有字幕")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString: "SubNow 会在检测到 mpv / IINA 播放缺少中文字幕的视频时，"
            + "以系统通知提醒你，确认后自动完成「转录原文 → 双语粗稿 → 精做热替换」的分阶段生成。"
            + "组件管理（ffmpeg / 模型 / 翻译引擎）将在设置中逐步提供。")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.preferredMaxLayoutWidth = 500

        versionLabel.font = .systemFont(ofSize: 12)
        versionLabel.textColor = .tertiaryLabelColor
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0-dev"
        versionLabel.stringValue = "版本 \(version)"

        container.addArrangedSubview(title)
        container.addArrangedSubview(subtitle)
        container.addArrangedSubview(versionLabel)

        let host = NSView()
        host.addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: host.topAnchor),
            container.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        return host
    }
}
