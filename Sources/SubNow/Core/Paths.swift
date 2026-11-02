import Foundation

/// 所有路径常量的唯一出处，避免多处硬编码导致漂移。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // Application Support 主目录
    static let appSupport: URL = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("SubNow", isDirectory: true)
    static let binDir: URL = appSupport.appendingPathComponent("bin", isDirectory: true)      // 下载的 ffmpeg 等工具
    static let tmpDir: URL = appSupport.appendingPathComponent("tmp", isDirectory: true)      // 任务工作目录
    /// 持久工作区：每部影片一个目录，保留音频、transcript.json 与全部字幕成品。
    static let workspaceDir: URL = appSupport.appendingPathComponent("workspace", isDirectory: true)
    static let stateFile: URL = appSupport.appendingPathComponent("state.json")
    static let historyFile: URL = {
        if let p = ProcessInfo.processInfo.environment["SUBNOW_HISTORY_FILE"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return appSupport.appendingPathComponent("history.json")
    }()
    static let lockFile: URL = appSupport.appendingPathComponent("subnow.lock")

    /// 未完成任务快照（音频/转录/阶段），与通知记账分开。
    /// 测试可用 SUBNOW_JOBS_FILE 指向临时文件，避免污染真实用户数据。
    static let jobsFile: URL = {
        if let p = ProcessInfo.processInfo.environment["SUBNOW_JOBS_FILE"], !p.isEmpty {
            return URL(fileURLWithPath: p)
        }
        return appSupport.appendingPathComponent("jobs.json")
    }()

    static let logFile: URL = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("SubNow.log")

    /// 模型目录：默认位置；已有模型直接复用（可在设置中更改）。
    static let defaultModelsDir: URL = home.appendingPathComponent("models/whisper-cpp", isDirectory: true)

    /// mpv/IINA IPC socket 默认候选（自定义路径由设置项另行附加）。
    static var socketCandidates: [String] { ["/tmp/subnow-mpv.sock"] }

    static func ensureAll() {
        let dirs = [appSupport, binDir, tmpDir, workspaceDir,
                    logFile.deletingLastPathComponent(), defaultModelsDir]
        for d in dirs {
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        }
    }

    /// ggml 在 metallib 缺失时的回退：按 GGML_METAL_PATH_RESOURCES 找 kernels/ 源码。
    /// 把路径指向 SPM 资源 bundle 内 kernels/ 的父目录（存在才设，避免覆盖用户的显式设置）。
    static func installMetalResourceHint() {
        guard getenv("GGML_METAL_PATH_RESOURCES") == nil,
              let resURL = Bundle.main.resourceURL else { return }
        let candidates = [
            resURL.appendingPathComponent("SubNow_CWhisper.bundle/Contents/Resources", isDirectory: true),
            resURL.appendingPathComponent("SubNow_CWhisper.bundle/Resources", isDirectory: true),
        ]
        for dir in candidates where FileManager.default.fileExists(atPath: dir.appendingPathComponent("kernels").path) {
            setenv("GGML_METAL_PATH_RESOURCES", dir.path, 0)
            Log.info("Metal 回退资源目录: \(dir.path)")
            return
        }
    }
}
