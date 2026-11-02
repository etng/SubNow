import Foundation
import WhisperBridge

/// 内嵌 whisper.cpp 引擎的 Swift 封装（Metal 加速，进程内调用）。
/// 一个引擎实例对应一个模型；草稿/精做各建一个，用完释放。
final class WhisperEngine {
    private var ctx: OpaquePointer?
    let modelURL: URL

    /// Metal 设备由 ggml 全局持有，加载/销毁交错会踩到同一套 residency/kernel 状态。
    /// 草稿与精做可能前后脚换模型，这里串行化生命周期。
    private static let lifecycleLock = NSLock()

    init(modelURL: URL, vadURL: URL?) throws {
        self.modelURL = modelURL
        var err = [CChar](repeating: 0, count: 1024)
        let vadPath = vadURL?.path
        Self.lifecycleLock.lock()
        defer { Self.lifecycleLock.unlock() }
        ctx = modelURL.path.withCString { modelPath in
            vadPath?.withCString { vad in snwh_load(modelPath, vad, &err, 1024) }
                ?? snwh_load(modelPath, nil, &err, 1024)
        }
        guard let ctx else {
            throw WhisperError.load(String(cString: err))
        }
        // 显存被占满时 whisper 会静默退回 CPU；记下来便于后续判断是否值得重试/降模型
        if snwh_gpu_fallback(ctx) != 0 {
            Log.warn("whisper GPU 初始化失败，已自动降级 CPU：\(modelURL.lastPathComponent)")
        } else {
            Log.info("whisper 后端：\(snwh_uses_gpu(ctx) != 0 ? "Metal" : "CPU")（\(modelURL.lastPathComponent)）")
        }
    }

    deinit {
        Self.lifecycleLock.lock()
        defer { Self.lifecycleLock.unlock() }
        if let ctx { snwh_free(ctx) }
    }

    enum WhisperError: LocalizedError {
        case load(String)
        case run(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .load(let m): return "模型加载失败：\(m)"
            case .run(let m): return "转录失败：\(m)"
            case .cancelled: return "已取消"
            }
        }
    }

    /// 转录 16k 单声道 wav。progress: 0-100。
    func run(wavURL: URL, language: String,
             progress: @escaping (Int) -> Void,
             isCancelled: @escaping () -> Bool) throws -> (segments: [Segment], language: String) {
        guard let ctx else { throw WhisperError.load("引擎未初始化") }
        guard !isCancelled() else { throw CancellationError() }

        final class Box {
            let progress: (Int) -> Void
            let isCancelled: () -> Bool
            init(_ p: @escaping (Int) -> Void, _ c: @escaping () -> Bool) {
                progress = p
                isCancelled = c
            }
        }
        let box = Box(progress, isCancelled)
        let opaque = Unmanaged.passRetained(box).toOpaque()

        var err = [CChar](repeating: 0, count: 1024)

        let progressCB: @convention(c) (UnsafeMutableRawPointer?, Int32) -> Void = { ud, percent in
            guard let ud else { return }
            let box = Unmanaged<Box>.fromOpaque(ud).takeUnretainedValue()
            box.progress(Int(percent))
        }
        let abortCB: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { ud in
            // 桥约定：返回 false = 请求中止
            guard let ud else { return false }
            let box = Unmanaged<Box>.fromOpaque(ud).takeUnretainedValue()
            return !box.isCancelled()
        }

        let rc = wavURL.path.withCString { wav in
            language.withCString { lang in
                snwh_run(ctx, wav, lang, progressCB, opaque, abortCB, opaque, &err, 1024)
            }
        }
        Unmanaged<Box>.fromOpaque(opaque).release()

        switch rc {
        case 0: break
        case -2: throw CancellationError()
        default: throw WhisperError.run(String(cString: err))
        }

        var segments: [Segment] = []
        let count = snwh_segment_count(ctx)
        for i in 0..<count {
            let textPtr = snwh_segment_text(ctx, i)
            let text = textPtr.map { Segments.cleanText(String(cString: $0)) } ?? ""
            guard !text.isEmpty else { continue }
            segments.append(Segment(start: Int(snwh_segment_t0(ctx, i)),
                                    end: Int(snwh_segment_t1(ctx, i)),
                                    src: text, zh: nil))
        }
        let lang = snwh_detected_language(ctx).map { String(cString: $0) } ?? "auto"
        // 时间轴缩水通常意味着单位/映射出错，宁可留下日志也不要静默产出错位字幕
        let audioMs = snwh_audio_ms(ctx)
        if audioMs > 60_000, let last = segments.last, last.end < audioMs / 2 {
            Log.warn("转录时间轴疑似异常：字幕结束于 \(last.end / 1000)s，音频总长 \(audioMs / 1000)s")
        }
        return (segments, lang)
    }
}
