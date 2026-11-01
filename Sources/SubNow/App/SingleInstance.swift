import AppKit
import Darwin

/// 单实例守卫：双保险。
/// 1) 打包后的 .app：按 Bundle ID 查 NSRunningApplication（进程死了无残留，最可靠）；
/// 2) swift run 开发模式（无 Bundle ID）：flock 文件锁（内核随进程释放，无 stale 问题）。
/// 冲突时必须给出提示——历史应用静默 exit(0)，双击图标没反应，是大忌。
enum SingleInstance {
    private static var lockFD: Int32 = -1

    static func acquire() -> Bool {
        let me = NSRunningApplication.current
        if let bid = Bundle.main.bundleIdentifier, !bid.isEmpty {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0 != me }
            if !others.isEmpty { return false }
        }

        let fd = open(Paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            Log.warn("无法打开锁文件 \(Paths.lockFile.path)（errno=\(errno)），跳过 flock 检查")
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            close(fd)
            return false
        }
        lockFD = fd  // 进程存活期间持有；退出由内核释放
        return true
    }

    static func conflictAlertAndExit() -> Never {
        let alert = NSAlert()
        alert.messageText = "SubNow 已在运行"
        alert.informativeText = "菜单栏右上角应该已有 SubNow 图标，请直接从那里使用。"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(0)
    }
}
