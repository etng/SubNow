import CryptoKit
import Foundation

/// 任务去重键：标准化路径的 SHA-256 前 16 位。
/// 同一个文件（含符号链接/相对路径）始终落到同一个工作目录与同一条持久化记录。
enum JobKeys {
    static func path(_ raw: String) -> String {
        let normalized = URL(fileURLWithPath: raw)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }
}

/// 视频指纹：同路径被替换成另一个文件时，旧进度必须作废。
struct FileFingerprint: Codable, Equatable {
    var size: Int64
    var mtime: Int

    static func read(_ path: String) -> FileFingerprint? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int(((attrs[.modificationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        return FileFingerprint(size: size, mtime: mtime)
    }
}

/// jobs.json 的一条记录。只保存可恢复的检查点，不保存 Task/Token。
struct PersistedJob: Codable {
    var videoPath: String
    var key: String
    var fingerprint: FileFingerprint?
    var stage: String
    var pct: Double
    var detail: String
    var workDir: String?
    var audioReady: Bool
    var draft: JobManager.Transcript?
    var draftReady: Bool
    var final: JobManager.Transcript?
    var originalNotified: Bool
    var draftNotified: Bool
    var finalNotified: Bool
    var updatedAt: Date
}

enum JobPersistence {
    static func load(from url: URL = Paths.jobsFile) -> [String: PersistedJob] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        guard let records = try? JSONDecoder().decode([String: PersistedJob].self, from: data) else {
            Log.error("任务表解析失败（\(url.path)），按空任务表处理")
            return [:]
        }
        return records
    }

    static func write(_ records: [String: PersistedJob], to url: URL = Paths.jobsFile) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            Log.error("jobs.json 写入失败: \(error.localizedDescription)")
        }
    }
}
