import Foundation

/// 一次性整理旧版本遗留在视频目录里的材料：
/// `.segments.json` / `.whisper.json` 移入工作区，已有成品复制一份归档，并建立历史记录。
/// 未被导出设置勾选的成品会从视频目录移走（工作区仍保留全部），让视频目录只留勾选项。
@MainActor
enum WorkspaceMigrator {
    private static let materialSuffixes = [".segments.json", ".whisper.json"]

    @discardableResult
    static func migrateIfNeeded() -> Int {
        var dirs = Set<URL>()
        for rec in JobPersistence.load().values {
            dirs.insert(URL(fileURLWithPath: rec.videoPath).deletingLastPathComponent())
        }
        for rec in HistoryStore.load() {
            dirs.insert(URL(fileURLWithPath: rec.videoPath).deletingLastPathComponent())
        }
        for path in playbackPaths() {
            dirs.insert(URL(fileURLWithPath: path).deletingLastPathComponent())
        }

        var migrated = 0
        for dir in dirs where FileManager.default.fileExists(atPath: dir.path) {
            migrated += migrate(directory: dir)
        }
        if migrated > 0 {
            Log.info("旧材料迁移完成：\(migrated) 部影片")
        }
        return migrated
    }

    private static func playbackPaths() -> [String] {
        guard let data = try? Data(contentsOf: Paths.stateFile),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return raw.values.compactMap { ($0 as? [String: Any])?["path"] as? String }
    }

    private static func migrate(directory dir: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return 0
        }
        let stems = Set(entries.compactMap { url -> String? in
            let name = url.lastPathComponent
            for suffix in materialSuffixes where name.hasSuffix(suffix) {
                return String(name.dropLast(suffix.count))
            }
            return nil
        })

        var count = 0
        for stem in stems {
            let video = videoURL(stem: stem, in: dir)
            let key = JobKeys.path(video.path)
            let workDir: URL
            do {
                workDir = try Workspace.create(for: key)
            } catch {
                Log.warn("迁移工作区创建失败（\(stem)）：\(error.localizedDescription)")
                continue
            }

            moveMaterial(named: "\(stem).segments.json", to: workDir.appendingPathComponent("segments.json"),
                         fallbackName: "segments.imported.json", dir: dir)
            moveMaterial(named: "\(stem).whisper.json", to: workDir.appendingPathComponent("whisper.json"),
                         fallbackName: "whisper.imported.json", dir: dir)
            archiveOutputs(stem: stem, key: key, dir: dir)
            if !HistoryStore.load().contains(where: { $0.key == key }) {
                HistoryStore.upsert(makeRecord(stem: stem, video: video, key: key, workDir: workDir, dir: dir))
            }
            count += 1
        }
        return count
    }

    private static func videoURL(stem: String, in dir: URL) -> URL {
        let fm = FileManager.default
        for ext in ["mkv", "mp4", "m4v", "mov", "ts", "webm", "avi"] {
            let candidate = dir.appendingPathComponent("\(stem).\(ext)")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return dir.appendingPathComponent("\(stem).mkv")
    }

    private static func moveMaterial(named name: String, to dest: URL,
                                     fallbackName: String, dir: URL) {
        let fm = FileManager.default
        let src = dir.appendingPathComponent(name)
        guard fm.fileExists(atPath: src.path) else { return }
        var target = dest
        if fm.fileExists(atPath: dest.path) {
            target = dest.deletingLastPathComponent().appendingPathComponent(fallbackName)
        }
        do {
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: src, to: target)
            Log.info("迁移材料：\(src.lastPathComponent) → \(target.path)")
        } catch {
            Log.warn("迁移材料失败（\(name)）：\(error.localizedDescription)")
        }
    }

    private static func archiveOutputs(stem: String, key: String, dir: URL) {
        let fm = FileManager.default
        let lang = language(key: key)
        let keep = Config.shared.exportKinds
        for kind in OutputKind.allCases {
            let name = kind.fileName(stem: stem, language: lang)
            let src = dir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else { continue }
            let dst = Workspace.outputURL(for: kind, key: key, stem: stem, language: lang)
            if !fm.fileExists(atPath: dst.path) {
                do {
                    try fm.copyItem(at: src, to: dst)
                } catch {
                    Log.warn("归档成品失败（\(name)）：\(error.localizedDescription)")
                    continue
                }
            }
            // 工作区已有副本；视频目录只保留当前勾选的导出种类
            if !keep.contains(kind) {
                try? fm.removeItem(at: src)
                Log.info("整理视频目录：\(name) 已移入工作区")
            }
        }
    }

    private static func language(key: String) -> String {
        let file = Workspace.dir(for: key).appendingPathComponent("segments.json")
        return Writers.readSegmentsFile(from: file)?.language ?? "orig"
    }

    private static func makeRecord(stem: String, video: URL, key: String,
                                   workDir: URL, dir: URL) -> HistoryRecord {
        let fm = FileManager.default
        let segmentsFile = workDir.appendingPathComponent("segments.json")
        let segments = Writers.readSegmentsFile(from: segmentsFile)
        let lang = segments?.language ?? "orig"
        let exports = OutputKind.allCases.filter {
            fm.fileExists(atPath: dir.appendingPathComponent($0.fileName(stem: stem, language: lang)).path)
        }
        let dates = exports.compactMap { kind -> Date? in
            let url = dir.appendingPathComponent(kind.fileName(stem: stem, language: lang))
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        let segmentDate = (try? segmentsFile.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return HistoryRecord(key: key, videoPath: video.path,
                             title: video.deletingPathExtension().lastPathComponent,
                             language: lang, finishedAt: dates.max() ?? segmentDate ?? Date(),
                             segmentCount: segments?.segments.count ?? 0,
                             status: exports.isEmpty ? "已归档" : "已完成",
                             workDir: workDir.path,
                             exported: exports.map(\.rawValue))
    }
}
