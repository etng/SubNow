import Foundation

/// 提取期间因播放让路而累计的暂停时长，供超时判断扣除。
final class PauseStats: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulated: TimeInterval = 0
    private var pausedAt: Date?
    private var count = 0

    func beginPause() {
        lock.lock()
        defer { lock.unlock() }
        guard pausedAt == nil else { return }
        pausedAt = Date()
        count += 1
    }

    func endPause() {
        lock.lock()
        defer { lock.unlock() }
        guard let started = pausedAt else { return }
        accumulated += Date().timeIntervalSince(started)
        pausedAt = nil
    }

    var pausedSeconds: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return accumulated + (pausedAt.map { Date().timeIntervalSince($0) } ?? 0)
    }

    var pauseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// 音频提取：ffmpeg → 16kHz 单声道 PCM16 wav（whisper 输入格式，桥内严格校验）。
/// 超时由上层 withTimeout 统一控制（置取消标记 → 本函数杀进程），这里不再维护第二层超时。
enum AudioExtractor {
    struct ExtractError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// volumePath 用于检测同卷播放：播放中给 ffmpeg 发 SIGSTOP，播放暂停/结束后 SIGCONT。
    /// onProgress 由 `-progress pipe:1` 驱动，fraction 需要 totalDuration 才能计算（否则为 nil）。
    static func extract(video: URL, to wav: URL, ffmpeg: URL, volumePath: String? = nil,
                        totalDuration: TimeInterval? = nil,
                        isCancelled: @escaping () -> Bool,
                        stats: PauseStats = PauseStats(),
                        onProgress: (@Sendable (Double?, TimeInterval) -> Void)? = nil,
                        onPauseChanged: (@Sendable (Bool) -> Void)? = nil) async throws {
        // 先写 .part 再原子改名：中断/崩溃时不会留下「看起来完整」的半截 wav
        let partial = wav.appendingPathExtension("part")
        try? FileManager.default.removeItem(at: partial)
        defer { try? FileManager.default.removeItem(at: partial) }

        let process = Process()
        process.executableURL = ffmpeg
        // 后台搬运/转码：不跟用户正在看的播放器抢前台 CPU 与 I/O
        process.qualityOfService = .utility
        process.arguments = [
            "-y", "-hide_banner", "-loglevel", "error", "-nostats",
            "-progress", "pipe:1",
            "-i", video.path,
            "-vn", "-ac", "1", "-ar", "16000",
            "-f", "wav",
            partial.path,
        ]
        process.standardError = FileHandle.nullDevice
        let progressPipe = Pipe()
        process.standardOutput = progressPipe

        try process.run()
        ProcessRegistry.shared.register(process)
        defer {
            ProcessRegistry.shared.unregister(process)
            if process.isRunning { process.terminate() }
        }

        // 逐行读取 ffmpeg 的 progress 输出；进程退出/管道断开时自然结束。
        let progressReader = Task.detached(priority: .utility) {
            var buffer = Data()
            while true {
                guard let chunk = try? progressPipe.fileHandleForReading.read(upToCount: 4096),
                      !chunk.isEmpty else { break }
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer[buffer.startIndex..<newline]
                    buffer = buffer[buffer.index(after: newline)...]
                    guard let line = String(data: lineData, encoding: .utf8),
                          let micros = microseconds(from: line) else { continue }
                    let seconds = micros / 1_000_000
                    let fraction = totalDuration.flatMap { total in
                        total > 0 ? min(max(seconds / total, 0), 0.99) : nil
                    }
                    onProgress?(fraction, seconds)
                }
            }
        }

        // 取消/超时 → 立即终止；同卷播放 → SIGSTOP 让出 I/O，播放结束再 SIGCONT。
        // 被暂停的进程收不到 SIGTERM，终止前必须先 SIGCONT。
        let cancelWatch = Task {
            var paused = false
            while true {
                if isCancelled() || Task.isCancelled {
                    if paused {
                        if process.isRunning { kill(process.processIdentifier, SIGCONT) }
                        stats.endPause()
                        paused = false
                    }
                    if process.isRunning { process.terminate() }
                    return
                }
                let busy = PlaybackGate.shared.isBusy(volumePath: volumePath)
                if busy, !paused, process.isRunning {
                    if kill(process.processIdentifier, SIGSTOP) == 0 {
                        stats.beginPause()
                        paused = true
                        Log.info("音频提取暂停：同一存储卷正在播放")
                        onPauseChanged?(true)
                    }
                } else if !busy, paused {
                    if process.isRunning { kill(process.processIdentifier, SIGCONT) }
                    stats.endPause()
                    paused = false
                    Log.info("音频提取继续：播放已暂停或结束")
                    onPauseChanged?(false)
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
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

        // 等管道读完，确保最后一行进度也回调出去。
        _ = await progressReader.value

        guard FileManager.default.fileExists(atPath: partial.path) else {
            throw ExtractError(message: "ffmpeg 未产出音频文件")
        }
        try? FileManager.default.removeItem(at: wav)
        try FileManager.default.moveItem(at: partial, to: wav)
        if stats.pauseCount > 0 {
            Log.info("音频提取完成（为播放让路 \(stats.pauseCount) 次，累计 \(Int(stats.pausedSeconds)) 秒）")
        }
    }

    /// ffmpeg 的 out_time_us/out_time_ms 都是微秒；`N/A` 直接丢弃。
    static func microseconds(from line: String) -> Double? {
        let raw: Substring
        if line.hasPrefix("out_time_us=") {
            raw = line.dropFirst("out_time_us=".count)
        } else if line.hasPrefix("out_time_ms=") {
            raw = line.dropFirst("out_time_ms=".count)
        } else {
            return nil
        }
        return Double(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
