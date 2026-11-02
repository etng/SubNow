import Foundation
import os

enum LogLevel: String {
    case debug, info, warn, error
}

/// 双通道日志：os.Logger（系统统一日志）+ ~/Library/Logs/SubNow.log（人肉排查用）。
/// 所有文件操作与时间戳格式化都在同一个串行队列内完成（DateFormatter 非线程安全）。
enum Log {
    private static let queue = DispatchQueue(label: "com.y10n.subnow.log")
    private static let oslog = Logger(subsystem: "com.y10n.subnow", category: "app")
    private static var fileHandle: FileHandle?
    private static var bytesInFile: UInt64 = 0
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func setup() {
        queue.sync { openIfNeeded() }
    }

    static func debug(_ msg: @autoclosure () -> String) { write(.debug, msg()) }
    static func info(_ msg: @autoclosure () -> String) { write(.info, msg()) }
    static func warn(_ msg: @autoclosure () -> String) { write(.warn, msg()) }
    static func error(_ msg: @autoclosure () -> String) { write(.error, msg()) }

    /// 等待队列中未落盘的日志写完（进程退出前必须调用，否则最后的清理日志会丢）
    static func flush() {
        queue.sync { }
    }

    private static func write(_ level: LogLevel, _ msg: @autoclosure () -> String) {
        let text = msg()
        queue.async {
            let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(text)"
            oslog.log(level: osLevel(level), "\(line, privacy: .public)")
            guard let data = (line + "\n").data(using: .utf8) else { return }
            if fileHandle == nil { openIfNeeded() }
            if bytesInFile + UInt64(data.count) > maxFileBytes { rotate() }
            try? fileHandle?.write(contentsOf: data)
            bytesInFile += UInt64(data.count)
            #if DEBUG
            FileHandle.standardError.write(data)
            #endif
        }
    }

    private static func openIfNeeded() {
        guard fileHandle == nil else { return }
        let path = Paths.logFile.path
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
        _ = try? fileHandle?.seekToEnd()
        bytesInFile = (try? fileHandle?.offsetInFile) ?? 0
    }

    /// 按大小轮转：SubNow.log → SubNow.log.1（只保留一份历史）
    private static func rotate() {
        try? fileHandle?.close()
        fileHandle = nil
        let current = Paths.logFile
        let previous = current.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: previous)
        try? FileManager.default.moveItem(at: current, to: previous)
        openIfNeeded()
    }

    private static func osLevel(_ level: LogLevel) -> OSLogType {
        switch level {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .default
        case .error: return .error
        }
    }
}
