import Foundation

/// 版本与构建信息。发布包由 make_app.sh 写入 Info.plist；
/// `swift run` 等无 Info.plist 的开发构建回退到可执行文件修改时间。
enum BuildInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static var version: String {
        nonEmpty(info["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static var buildNumber: String {
        nonEmpty(info["CFBundleVersion"] as? String) ?? "dev"
    }

    static var gitCommit: String? {
        nonEmpty(info["SUGitCommit"] as? String)
    }

    static var buildTime: String {
        if let raw = nonEmpty(info["SUBuildTime"] as? String),
           let date = ISO8601DateFormatter().date(from: raw) {
            return displayFormatter.string(from: date)
        }
        if let exe = Bundle.main.executableURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path),
           let date = attrs[.modificationDate] as? Date {
            return displayFormatter.string(from: date) + "（开发构建）"
        }
        return "未知"
    }

    static var summary: String {
        var text = "SubNow \(version)（build \(buildNumber)） · 编译于 \(buildTime)"
        if let gitCommit { text += " · \(gitCommit)" }
        return text
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value != "unknown" else { return nil }
        return value
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}
