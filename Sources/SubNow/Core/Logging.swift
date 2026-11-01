import Foundation
import os

enum LogLevel: String {
    case debug, info, warn, error
}

/// 双通道日志：os.Logger（系统统一日志）+ ~/Library/Logs/SubNow.log（人肉排查用）。
enum Log {
    private static let queue = DispatchQueue(label: "com.y10n.subnow.log")
    private static let oslog = Logger(subsystem: "com.y10n.subnow", category: "app")
    private static var fileHandle: FileHandle?
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func setup() {
        queue.sync {
            if fileHandle == nil {
                let path = Paths.logFile.path
                if !FileManager.default.fileExists(atPath: path) {
                    FileManager.default.createFile(atPath: path, contents: nil)
                }
                fileHandle = try? FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try? fileHandle?.seekToEnd()
            }
        }
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
        let line = "\(formatter.string(from: Date())) [\(level.rawValue.uppercased())] \(msg())"
        queue.async {
            oslog.log(level: osLevel(level), "\(line, privacy: .public)")
            if let data = (line + "\n").data(using: .utf8), let fh = fileHandle {
                try? fh.write(contentsOf: data)
            }
            #if DEBUG
            if let errData = (line + "\n").data(using: .utf8) {
                FileHandle.standardError.write(errData)
            }
            #endif
        }
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
