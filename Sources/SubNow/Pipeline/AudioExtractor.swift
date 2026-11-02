import Foundation

/// 音频提取：ffmpeg → 16kHz 单声道 PCM16 wav（whisper 输入格式，桥内严格校验）。
/// 超时由上层 withTimeout 统一控制（置取消标记 → 本函数杀进程），这里不再维护第二层超时。
enum AudioExtractor {
    struct ExtractError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func extract(video: URL, to wav: URL, ffmpeg: URL,
                        isCancelled: @escaping () -> Bool) async throws {
        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = [
            "-y", "-loglevel", "error",
            "-i", video.path,
            "-vn", "-ac", "1", "-ar", "16000",
            wav.path,
        ]
        process.standardError = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        try process.run()
        ProcessRegistry.shared.register(process)
        defer {
            ProcessRegistry.shared.unregister(process)
            if process.isRunning { process.terminate() }
        }

        // 取消/超时 → 立即终止；外层 Task 被取消时同样要杀进程，否则结构化并发会一直等它。
        let cancelWatch = Task {
            while true {
                if isCancelled() || Task.isCancelled {
                    if process.isRunning { process.terminate() }
                    return
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        defer { cancelWatch.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { proc in
                if proc.terminationStatus == 0 {
                    cont.resume()
                } else if isCancelled() {
                    cont.resume(throwing: CancellationError())
                } else {
                    cont.resume(throwing: ExtractError(message: "ffmpeg 退出码 \(proc.terminationStatus)"))
                }
            }
        }

        guard FileManager.default.fileExists(atPath: wav.path) else {
            throw ExtractError(message: "ffmpeg 未产出音频文件")
        }
    }
}
