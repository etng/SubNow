import Foundation

/// 所有路径常量的唯一出处——POC 调研结果四份文件各自硬编码同一路径导致漂移，禁止重蹈。
enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // Application Support 主目录
    static let appSupport: URL = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("SubNow", isDirectory: true)
    static let binDir: URL = appSupport.appendingPathComponent("bin", isDirectory: true)      // 下载的 ffmpeg 等工具
    static let tmpDir: URL = appSupport.appendingPathComponent("tmp", isDirectory: true)      // 任务工作目录
    static let stateFile: URL = appSupport.appendingPathComponent("state.json")
    static let lockFile: URL = appSupport.appendingPathComponent("subnow.lock")

    static let logFile: URL = home
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Logs", isDirectory: true)
        .appendingPathComponent("SubNow.log")

    /// 模型目录：默认沿用POC 调研结果位置，已有的模型直接复用（可在设置中更改）。
    static let defaultModelsDir: URL = home.appendingPathComponent("models/whisper-cpp", isDirectory: true)

    /// mpv/IINA IPC socket 候选：新默认 + POC 调研结果兼容。
    static var socketCandidates: [String] { ["/tmp/subnow-mpv.sock", "/tmp/poc-mpv.sock"] }

    static func ensureAll() {
        let dirs = [appSupport, binDir, tmpDir, logFile.deletingLastPathComponent(), defaultModelsDir]
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
