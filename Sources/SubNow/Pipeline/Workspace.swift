import Foundation

/// 成品字幕种类：工作区总是保留全部种类，是否复制到视频目录由设置决定。
enum OutputKind: String, CaseIterable, Codable {
    case zhTopAss
    case zhBottomAss
    case chineseSrt
    case originalSrt

    static let defaults: Set<OutputKind> = [.zhTopAss]

    var label: String {
        switch self {
        case .zhTopAss: return "双语 ASS（中文在上）"
        case .zhBottomAss: return "双语 ASS（中文在下）"
        case .chineseSrt: return "中文 SRT"
        case .originalSrt: return "原文 SRT"
        }
    }

    func fileName(stem: String, language: String) -> String {
        switch self {
        case .zhTopAss: return "\(stem).ass"
        case .zhBottomAss: return "\(stem).zh-bottom.ass"
        case .chineseSrt: return "\(stem).zh.srt"
        case .originalSrt: return Writers.originalSrtName(stem: stem, language: language)
        }
    }
}

/// 一条已完成/已归档记录。历史窗口与工作区目录都以此为准。
struct HistoryRecord: Codable, Identifiable {
    var key: String
    var videoPath: String
    var title: String
    var language: String
    var finishedAt: Date
    var segmentCount: Int
    var status: String
    var workDir: String
    var exported: [String]

    var id: String { key }

    var videoExists: Bool {
        FileManager.default.fileExists(atPath: videoPath)
    }

    func exportedKinds() -> Set<OutputKind> {
        Set(exported.compactMap(OutputKind.init(rawValue:)))
    }
}

enum HistoryStore {
    static func load(from url: URL = Paths.historyFile) -> [HistoryRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let records = try? decoder.decode([HistoryRecord].self, from: data) else {
            Log.error("历史记录解析失败（\(url.path)），按空记录处理")
            return []
        }
        return records.sorted { $0.finishedAt > $1.finishedAt }
    }

    static func save(_ records: [HistoryRecord], to url: URL = Paths.historyFile) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(records).write(to: url, options: .atomic)
        } catch {
            Log.error("历史记录写入失败: \(error.localizedDescription)")
        }
    }

    static func upsert(_ record: HistoryRecord, to url: URL = Paths.historyFile) {
        var records = load(from: url).filter { $0.key != record.key }
        records.append(record)
        save(records, to: url)
    }

    static func remove(key: String, from url: URL = Paths.historyFile) {
        save(load(from: url).filter { $0.key != key }, to: url)
    }
}

enum Workspace {
    static func dir(for key: String) -> URL {
        Paths.workspaceDir.appendingPathComponent("job-\(key)", isDirectory: true)
    }

    static func outputsDir(for key: String) -> URL {
        dir(for: key).appendingPathComponent("outputs", isDirectory: true)
    }

    static func create(for key: String) throws -> URL {
        let root = dir(for: key)
        try FileManager.default.createDirectory(at: outputsDir(for: key), withIntermediateDirectories: true)
        return root
    }

    static func existingDir(for key: String) -> URL? {
        let root = dir(for: key)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return root
    }

    static func outputURL(for kind: OutputKind, key: String, stem: String, language: String) -> URL {
        outputsDir(for: key).appendingPathComponent(kind.fileName(stem: stem, language: language))
    }

    /// 把已生成的成品复制到视频目录；只复制用户勾选的种类。
    /// pruneOthers=true 时同时移除未勾选的已知成品，保证视频目录与设置一致。
    static func export(_ kinds: Set<OutputKind>, key: String, stem: String, language: String,
                       to videoDir: URL, pruneOthers: Bool = false) throws -> [OutputKind] {
        var exported: [OutputKind] = []
        for kind in OutputKind.allCases where kinds.contains(kind) {
            let src = outputURL(for: kind, key: key, stem: stem, language: language)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = videoDir.appendingPathComponent(kind.fileName(stem: stem, language: language))
            if FileManager.default.fileExists(atPath: dst.path) {
                try? FileManager.default.removeItem(at: dst)
            }
            try FileManager.default.copyItem(at: src, to: dst)
            exported.append(kind)
        }
        if pruneOthers {
            for kind in OutputKind.allCases where !kinds.contains(kind) {
                let url = videoDir.appendingPathComponent(kind.fileName(stem: stem, language: language))
                try? FileManager.default.removeItem(at: url)
            }
        }
        return exported
    }

    static func size(of url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
