import Foundation

/// 播放器记账（state.json）：避免对同一视频反复询问。
/// 键 = path|size|mtime；失效规则与POC 调研结果一致：
/// - done / has-subs / failed / skipped：永久静默；
/// - 但若记录声称"有外挂字幕"而字幕文件已被删除 → 作废，重新判定；
/// - processing / draft-done：应用存活期间跳过；重启后变 queued-restart，重新触发。
actor PlayerBook {
    struct Record: Codable {
        var status: String
        var path: String
        var sidecar: Bool
        var updated: Date
        var pid: Int?
    }

    private var records: [String: Record] = [:]
    private let fileURL = Paths.stateFile

    init() {
        load()
        // 重启后遗留的处理中/粗稿完成 → 重新可触发（等下次播放判定）
        for (key, var r) in records where r.status == "processing" || r.status == "draft-done" {
            r.status = "queued-restart"
            r.updated = Date()
            records[key] = r
        }
        if !records.isEmpty { save() }
    }

    // MARK: - 键

    nonisolated static func key(for video: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: video.path)
        let size = (attrs?[.size] as? Int64) ?? 0
        let mtime = Int(((attrs?[.modificationDate] as? Date) ?? Date()).timeIntervalSince1970)
        return "\(video.path)|\(size)|\(mtime)"
    }

    // MARK: - 查询/写入

    func record(for video: URL) -> Record? {
        records[Self.key(for: video)]
    }

    func set(_ status: String, for video: URL, sidecar: Bool, pid: Int? = nil) {
        records[Self.key(for: video)] = Record(status: status, path: video.path,
                                               sidecar: sidecar, updated: Date(), pid: pid)
        save()
    }

    /// 该视频是否应被静默跳过（含 sidecar 失效校验）
    func shouldSkip(video: URL, sidecarExistsNow: Bool) -> Bool {
        guard let r = records[Self.key(for: video)] else { return false }
        switch r.status {
        case "processing", "draft-done":
            return true
        case "has-subs", "done", "failed", "skipped":
            // 声称有外挂但现在没了 → 不再静默，重新判定
            if r.sidecar && !sidecarExistsNow {
                records.removeValue(forKey: Self.key(for: video))
                save()
                return false
            }
            return true
        default:
            return false  // queued-restart 等：重新判定
        }
    }

    /// 万能重触发：按路径前缀清记账（"all" 清空）
    func forget(pathPrefix: String) -> Int {
        var removed = 0
        if pathPrefix == "all" {
            removed = records.count
            records.removeAll()
        } else {
            for (k, r) in records where r.path.hasPrefix(pathPrefix) {
                records.removeValue(forKey: k)
                removed += 1
            }
        }
        if removed > 0 { save() }
        return removed
    }

    // MARK: - 持久化（原子写）

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        records = (try? JSONDecoder().decode([String: Record].self, from: data)) ?? [:]
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            let tmp = fileURL.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try? FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        } catch {
            Log.error("state.json 写入失败: \(error.localizedDescription)")
        }
    }
}
