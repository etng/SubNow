import AppKit

extension Notification.Name {
    static let subNowHistoryChanged = Notification.Name("SubNowHistoryChanged")
}

/// 历史记录窗口：按影片查看工作区、重新导出成品、打开视频或清理材料。
@MainActor
final class HistoryWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = HistoryWindowController()

    private let table = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var records: [HistoryRecord] = []
    private var sizes: [String: Int64] = [:]
    private var actionButtons: [NSButton] = []
    private var observer: NSObjectProtocol?

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SubNow 历史记录"
        window.minSize = NSSize(width: 760, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.contentView = buildContent()
        observer = NotificationCenter.default.addObserver(
            forName: .subNowHistoryChanged, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadIfVisible() }
        }
    }

    required init?(coder: NSCoder) { fatalError("不支持") }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    func show() {
        reload()
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func reloadIfVisible() {
        guard window?.isVisible == true else { return }
        reload()
    }

    private func reload() {
        records = HistoryStore.load()
        sizes = [:]
        for rec in records {
            sizes[rec.key] = Workspace.size(of: URL(fileURLWithPath: rec.workDir))
        }
        countLabel.stringValue = records.isEmpty ? "尚无历史记录" : "共 \(records.count) 部影片"
        table.reloadData()
        if !records.isEmpty, table.selectedRow < 0 {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        updateButtons()
    }

    // MARK: - 布局

    private func buildContent() -> NSView {
        let root = NSView()

        let title = NSTextField(labelWithString: "历史记录")
        title.font = .systemFont(ofSize: 22, weight: .semibold)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        let heading = NSStackView(views: [title, countLabel])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 2

        let refresh = NSButton(title: "刷新", target: self, action: #selector(refreshClicked))
        refresh.bezelStyle = .rounded
        refresh.controlSize = .small

        let header = NSStackView(views: [heading, NSView(), refresh])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        configureTable()
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let buttons: [(String, Selector, Bool)] = [
            ("打开视频", #selector(openVideo), true),
            ("显示成品", #selector(revealOutputs), true),
            ("工作目录", #selector(openWorkDir), true),
            ("重新导出", #selector(reexport), true),
            ("删除…", #selector(deleteRecord), true),
        ]
        let buttonRow = NSStackView()
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        for (title, action, enabled) in buttons {
            let b = NSButton(title: title, target: self, action: action)
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.isEnabled = false
            _ = enabled
            actionButtons.append(b)
            buttonRow.addArrangedSubview(b)
        }

        let footer = NSStackView(views: [buttonRow, NSView(), statusLabel])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 12

        for v in [header, scroll, footer] {
            v.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(v)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 18),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -12),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -14),
            footer.heightAnchor.constraint(equalToConstant: 26),
        ])
        return root
    }

    private func configureTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.target = self
        table.doubleAction = #selector(openVideo)

        let columns: [(String, String, CGFloat)] = [
            ("title", "影片", 360),
            ("status", "状态", 70),
            ("count", "字幕", 70),
            ("exported", "成品", 70),
            ("finished", "完成时间", 130),
            ("size", "占用", 80),
        ]
        for (id, title, width) in columns {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.minWidth = id == "title" ? 180 : 50
            col.resizingMask = id == "title" ? .autoresizingMask : .userResizingMask
            table.addTableColumn(col)
        }
        table.headerView = NSTableHeaderView()
    }

    private func updateButtons() {
        let selected = selectedRecord()
        for b in actionButtons { b.isEnabled = selected != nil }
        if let rec = selected {
            statusLabel.stringValue = rec.videoPath
        } else {
            statusLabel.stringValue = records.isEmpty ? "生成字幕后会自动出现在这里" : "选择一条记录查看操作"
        }
    }

    private func selectedRecord() -> HistoryRecord? {
        let row = table.selectedRow
        guard row >= 0, row < records.count else { return nil }
        return records[row]
    }

    // MARK: - 表格

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, row < records.count else { return nil }
        let rec = records[row]
        let id = tableColumn.identifier
        let text: String
        switch id.rawValue {
        case "title":
            text = rec.title
        case "status":
            text = rec.status
        case "count":
            text = rec.segmentCount > 0 ? "\(rec.segmentCount) 条" : "—"
        case "exported":
            text = rec.exported.isEmpty ? "仅工作区" : "\(rec.exported.count) 份"
        case "finished":
            text = Self.dateFormatter.string(from: rec.finishedAt)
        case "size":
            text = ByteCountFormatter.string(fromByteCount: sizes[rec.key] ?? 0, countStyle: .file)
        default:
            text = ""
        }
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = id.rawValue == "title" ? .byTruncatingMiddle : .byTruncatingTail
        label.font = id.rawValue == "title" ? .systemFont(ofSize: 13, weight: .medium) : .systemFont(ofSize: 12)
        label.textColor = id.rawValue == "status" && rec.status == "已完成" ? .labelColor : .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.toolTip = id.rawValue == "title" ? rec.videoPath : text
        cell.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - 动作

    @objc private func refreshClicked() { reload() }

    @objc private func openVideo() {
        guard let rec = selectedRecord() else { return }
        let url = URL(fileURLWithPath: rec.videoPath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            alert("视频当前不可达", "网络盘可能未挂载：\n\(rec.videoPath)")
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func revealOutputs() {
        guard let rec = selectedRecord() else { return }
        let videoDir = URL(fileURLWithPath: rec.videoPath).deletingLastPathComponent()
        let stem = URL(fileURLWithPath: rec.videoPath).deletingPathExtension().lastPathComponent
        let files = OutputKind.allCases.compactMap { kind -> URL? in
            let url = videoDir.appendingPathComponent(kind.fileName(stem: stem, language: rec.language))
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if files.isEmpty {
            let dir = URL(fileURLWithPath: rec.workDir).appendingPathComponent("outputs")
            if FileManager.default.fileExists(atPath: dir.path) {
                NSWorkspace.shared.open(dir)
            } else {
                alert("没有可显示的成品", "工作区或视频目录中都没有找到字幕文件。")
            }
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting(files)
    }

    @objc private func openWorkDir() {
        guard let rec = selectedRecord() else { return }
        let dir = URL(fileURLWithPath: rec.workDir)
        guard FileManager.default.fileExists(atPath: dir.path) else {
            alert("工作目录不存在", rec.workDir)
            return
        }
        NSWorkspace.shared.open(dir)
    }

    @objc private func reexport() {
        guard let rec = selectedRecord() else { return }
        let video = URL(fileURLWithPath: rec.videoPath)
        let stem = video.deletingPathExtension().lastPathComponent
        do {
            let exported = try Workspace.export(Config.shared.exportKinds, key: rec.key, stem: stem,
                                                language: rec.language,
                                                to: video.deletingLastPathComponent(),
                                                pruneOthers: true)
            var updated = rec
            updated.exported = exported.map(\.rawValue)
            HistoryStore.upsert(updated)
            reload()
            statusLabel.stringValue = exported.isEmpty
                ? "工作区里没有对应成品，请重新生成字幕"
                : "已导出：\(exported.map(\.label).joined(separator: "、"))"
        } catch {
            alert("导出失败", error.localizedDescription)
        }
    }

    @objc private func deleteRecord() {
        guard let rec = selectedRecord() else { return }
        let a = NSAlert()
        a.messageText = "删除「\(rec.title)」的历史记录？"
        a.informativeText = "工作区中的音频、JSON 与全部成品会一并删除；"
            + "已经复制到视频目录的字幕不会删除。"
        a.alertStyle = .warning
        a.addButton(withTitle: "删除记录和材料")
        a.addButton(withTitle: "取消")
        guard a.runModal() == .alertFirstButtonReturn else { return }

        try? FileManager.default.removeItem(atPath: rec.workDir)
        HistoryStore.remove(key: rec.key)
        reload()
    }

    private func alert(_ message: String, _ detail: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = detail
        a.alertStyle = .warning
        a.runModal()
    }
}
