import Foundation

/// 音频提取：ffmpeg → 16kHz 单声道 PCM16 wav（whisper 输入格式，桥内严格校验）。
enum AudioExtractor {
    struct ExtractError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// timeout 秒后强杀（提取卡死不拖垮任务）
    static func extract(video: URL, to wav: URL, ffmpeg: URL,
                        timeout: TimeInterval = 600,
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
        defer {
            if process.isRunning { process.terminate() }
        }

        // 取消 → 立即终止
        let cancelWatch = Task {
            while !Task.isCancelled {
                if isCancelled() {
                    if process.isRunning { process.terminate() }
                    return
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
        defer { cancelWatch.cancel() }

        // 超时强杀
        let timeoutWatch = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            if process.isRunning {
                Log.warn("音频提取超时（\(Int(timeout))s），强杀 ffmpeg")
                process.terminate()
            }
        }
        defer { timeoutWatch.cancel() }

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
