import Foundation

/// 组件就绪状态机。规则：全部必需组件就绪才允许"可生成"提醒；
/// 未就绪时只提示"尚未就绪"，绝不触发流水线。
@MainActor
final class ComponentCenter {
    static let shared = ComponentCenter()

    enum ComponentID: String, CaseIterable {
        case ffmpeg      // 音频提取 + 流探测
        case draftModel  // 草稿转录模型
        case vadModel    // Silero VAD
        case finalModel  // 精做转录模型（可选组件：缺失时精做阶段自动跳过）
        case translation // 翻译引擎（Ollama/兼容API/系统模型/不翻译）
    }

    enum State: Equatable {
        case ready(detail: String)
        case missing(detail: String)
        case downloading(progress: Double, detail: String)
        case broken(detail: String)   // 存在但损坏（尺寸不对等）
    }

    struct Status {
        var id: ComponentID
        var state: State
        var required: Bool
    }

    private(set) var statuses: [ComponentID: Status] = [:]
    private var downloadingTasks: [ComponentID: Task<Void, Never>] = [:]

    /// 状态变化回调（UI 刷新用）
    var onChange: (() -> Void)?

    // MARK: - 探测

    func refresh() {
        statuses[.ffmpeg] = probeFFmpeg()
        statuses[.draftModel] = probeModel(.draftModel, Config.shared.draftModelURL, minBytes: 1_000_000_000,
                                           name: "转录草稿模型（turbo）")
        statuses[.vadModel] = probeModel(.vadModel, Config.shared.vadModelURL, minBytes: 500_000,
                                         name: "Silero VAD 模型")
        statuses[.finalModel] = probeModel(.finalModel, Config.shared.finalModelURL, minBytes: 2_500_000_000,
                                           name: "转录精做模型（large-v3）", isRequired: false)
        statuses[.translation] = Status(id: .translation, state: translationState(), required: true)
        onChange?()
    }

    func status(_ id: ComponentID) -> Status? { statuses[id] }

    /// 基础就绪 = 必需组件全部 ready（允许生成草稿双语字幕）
    var isBaseReady: Bool {
        ComponentID.allCases
            .filter { statuses[$0]?.required ?? true }
            .allSatisfy {
                if case .ready = statuses[$0]?.state { return true }
                return false
            }
    }

    /// 精做就绪 = 基础就绪 + final 模型
    var isFinalReady: Bool {
        isBaseReady && {
            if case .ready = statuses[.finalModel]?.state { return true }
            return false
        }()
    }

    /// 未就绪原因清单（用于"尚未就绪"提示与菜单角标）
    var missingSummary: String {
        let missing = ComponentID.allCases.compactMap { id -> String? in
            guard let st = statuses[id], st.required else { return nil }
            if case .ready = st.state { return nil }
            if case .downloading = st.state { return nil }
            return Self.displayName(id)
        }
        return missing.isEmpty ? "" : "缺 " + missing.joined(separator: "、")
    }

    nonisolated static func displayName(_ id: ComponentID) -> String {
        switch id {
        case .ffmpeg: return "ffmpeg"
        case .draftModel: return "草稿模型"
        case .vadModel: return "VAD 模型"
        case .finalModel: return "精做模型"
        case .translation: return "翻译引擎"
        }
    }

    // MARK: - 探测实现

    private func probeFFmpeg() -> Status {
        if let url = FFmpegLocator.locate() {
            return Status(id: .ffmpeg, state: .ready(detail: url.path), required: true)
        }
        return Status(id: .ffmpeg, state: .missing(detail: "未找到 ffmpeg（brew 或手动安装均可）"), required: true)
    }

    private func probeModel(_ id: ComponentID, _ url: URL, minBytes: Int, name: String, isRequired: Bool = true) -> Status {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Status(id: id, state: .missing(detail: "\(name) 未下载"), required: isRequired)
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        if size < minBytes {
            return Status(id: id, state: .broken(detail: "\(name) 文件不完整（\(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))）"), required: isRequired)
        }
        return Status(id: id, state: .ready(detail: url.path), required: isRequired)
    }

    private func translationState() -> State {
        let kind = Config.shared.translationKind
        switch kind {
        case .none:
            return .ready(detail: "不翻译（仅原文）")
        case .appleFM:
            if let detail = AppleFMAvailability.describe() {
                return .ready(detail: detail)
            }
            return .missing(detail: "Apple 系统模型不可用（需 macOS 26+ 且开启 Apple Intelligence）")
        case .openAICompatible:
            let cfg = Config.shared
            if cfg.openAIBaseURL.isEmpty || cfg.openAIModel.isEmpty {
                return .missing(detail: "请在设置中填写 API 地址与模型名")
            }
            return .ready(detail: "\(cfg.openAIModel) @ \(cfg.openAIBaseURL)")
        case .ollama:
            return .missing(detail: "检测中…")  // 异步刷新为真实状态
        }
    }

    /// Ollama 异步探测（listModels + 目标模型是否已拉取）
    func refreshOllamaAsync() {
        let cfg = Config.shared
        guard cfg.translationKind == .ollama else { return }
        let baseURL = cfg.ollamaURL
        let needed = [cfg.ollamaDraftModel, cfg.ollamaFinalModel]
        Task { @MainActor in
            let models = (try? await OllamaManager.shared.listModels(baseURL: baseURL)) ?? []
            let state: State
            if models.isEmpty {
                state = .missing(detail: "Ollama 服务不可达（\(baseURL)）")
            } else {
                let haveDraft = models.contains(cfg.ollamaDraftModel)
                let haveFinal = models.contains(cfg.ollamaFinalModel)
                if haveDraft && haveFinal {
                    state = .ready(detail: "Ollama：\(cfg.ollamaDraftModel) + \(cfg.ollamaFinalModel)")
                } else if haveDraft {
                    state = .ready(detail: "Ollama：\(cfg.ollamaDraftModel)（精做模型缺 \(cfg.ollamaFinalModel)，仅影响精做）")
                    // 草稿翻译可用即视为基础就绪
                    statuses[.translation] = Status(id: .translation, state: state, required: true)
                    onChange?()
                    return
                } else {
                    state = .missing(detail: "Ollama 在线，但缺翻译模型 \(cfg.ollamaDraftModel)")
                }
            }
            statuses[.translation] = Status(id: .translation, state: state, required: true)
            onChange?()
        }
    }

    // MARK: - 动作

    /// 下载模型（HF 主源 + hf-mirror 回退，断点续传）
    func downloadModel(_ id: ComponentID) {
        guard downloadingTasks[id] == nil else { return }
        let spec: (url: URL, dest: URL, label: String)
        switch id {
        case .draftModel:
            spec = (HFSource.url(file: Config.shared.draftModelFile), Config.shared.draftModelURL, "草稿模型")
        case .finalModel:
            spec = (HFSource.url(file: Config.shared.finalModelFile), Config.shared.finalModelURL, "精做模型")
        case .vadModel:
            spec = (HFSource.vadURL(file: Config.shared.vadModelFile), Config.shared.vadModelURL, "VAD 模型")
        default:
            return
        }
        statuses[id]?.state = .downloading(progress: 0, detail: "连接中…")
        onChange?()
        downloadingTasks[id] = Task { @MainActor in
            defer { downloadingTasks[id] = nil }
            do {
                let stream = try await ModelDownloader.shared.download(
                    remote: spec.url, to: spec.dest, label: spec.label)
                for await progress in stream {
                    if Task.isCancelled { return }
                    switch progress {
                    case .progress(let frac, let detail):
                        statuses[id]?.state = .downloading(progress: frac, detail: detail)
                        onChange?()
                    case .finished:
                        refresh()
                        return
                    }
                }
            } catch is CancellationError {
                refresh()
            } catch {
                statuses[id]?.state = .broken(detail: "下载失败：\(error.localizedDescription)")
                onChange?()
            }
        }
    }

    func cancelDownload(_ id: ComponentID) {
        downloadingTasks[id]?.cancel()
    }

    func isDownloading(_ id: ComponentID) -> Bool {
        downloadingTasks[id] != nil
    }
}

/// HF 模型直链（主源 + 国内镜像回退）
enum HFSource {
    static func url(file: String) -> URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }
    static func mirrorURL(file: String) -> URL {
        URL(string: "https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/\(file)")!
    }
    static func vadURL(file: String) -> URL {
        URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/\(file)")!
    }
    static func vadMirrorURL(file: String) -> URL {
        URL(string: "https://hf-mirror.com/ggml-org/whisper-vad/resolve/main/\(file)")!
    }
}

enum FFmpegLocator {
    /// 搜索顺序：App 支持目录（手动/下载安装）→ Homebrew → 系统路径 → PATH
    static func locate() -> URL? {
        let candidates = [
            Paths.binDir.appendingPathComponent("ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return URL(fileURLWithPath: c)
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in path.split(separator: ":") {
            let p = URL(fileURLWithPath: String(dir)).appendingPathComponent("ffmpeg").path
            if FileManager.default.isExecutableFile(atPath: p) { return URL(fileURLWithPath: p) }
        }
        return nil
    }
}

/// Apple Foundation Models（系统翻译模型）可用性
enum AppleFMAvailability {
    static func describe() -> String? {
        guard #available(macOS 26, *) else { return nil }
        return "Apple 系统模型（随 Apple Intelligence 提供）"
    }
}
