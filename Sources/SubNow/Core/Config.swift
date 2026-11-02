import Foundation

enum TranslationKind: String {
    case ollama             // 本地 Ollama（默认，本机已就绪）
    case openAICompatible   // 任意 OpenAI 兼容 API（为未来接其他服务预留）
    case appleFM            // Apple 系统模型（macOS 26+）
    case none               // 仅原文，不翻译
}

/// 全部用户配置的唯一出处（UserDefaults 托管）。
@MainActor
final class Config {
    static let shared = Config()
    private let d = UserDefaults.standard

    private enum Key: String, CaseIterable {
        case modelsDir = "modelsDir"
        case pollSeconds = "pollSeconds"
        case minFileMB = "minFileMB"
        case language = "language"
        case autoAsk = "autoAsk"
        case autoFinal = "autoFinal"
        case lineLen = "lineLen"
        case batchSize = "batchSize"
        case maxConcurrent = "maxConcurrent"
        case customSocketPath = "customSocketPath"
        case translationKind = "translationKind"
        case ollamaURL = "ollamaURL"
        case ollamaDraftModel = "ollamaDraftModel"
        case ollamaFinalModel = "ollamaFinalModel"
        case openAIBaseURL = "openAIBaseURL"
        case openAIAPIKey = "openAIAPIKey"
        case openAIModel = "openAIModel"
        case draftModelFile = "draftModelFile"
        case finalModelFile = "finalModelFile"
        case vadModelFile = "vadModelFile"
        case exportOutputs = "exportOutputs"
        case hasCompletedSetup = "hasCompletedSetup"
    }

    private init() {
        UserDefaults.standard.register(defaults: [
            Key.pollSeconds.rawValue: 3.0,
            Key.minFileMB.rawValue: 10,
            Key.language.rawValue: "auto",
            Key.autoAsk.rawValue: true,
            Key.autoFinal.rawValue: true,
            Key.lineLen.rawValue: 20,
            Key.batchSize.rawValue: 30,
            Key.maxConcurrent.rawValue: 1,
            Key.customSocketPath.rawValue: "",
            Key.translationKind.rawValue: TranslationKind.ollama.rawValue,
            Key.ollamaURL.rawValue: "http://127.0.0.1:11434",
            Key.ollamaDraftModel.rawValue: "qwen2.5:7b",
            Key.ollamaFinalModel.rawValue: "qwen3.8:27b-mlx",
            Key.openAIBaseURL.rawValue: "",
            Key.openAIAPIKey.rawValue: "",
            Key.openAIModel.rawValue: "",
            Key.draftModelFile.rawValue: "ggml-large-v3-turbo.bin",
            Key.finalModelFile.rawValue: "ggml-large-v3.bin",
            Key.vadModelFile.rawValue: "ggml-silero-v5.1.2.bin",
            Key.exportOutputs.rawValue: OutputKind.defaults.map(\.rawValue),
            Key.hasCompletedSetup.rawValue: false,
        ])
    }

    // MARK: - 检测
    var pollSeconds: Double {
        get { d.double(forKey: Key.pollSeconds.rawValue) }
        set { d.set(newValue, forKey: Key.pollSeconds.rawValue) }
    }
    var minFileMB: Int {
        get { d.integer(forKey: Key.minFileMB.rawValue) }
        set { d.set(newValue, forKey: Key.minFileMB.rawValue) }
    }
    var language: String {
        get { d.string(forKey: Key.language.rawValue) ?? "auto" }
        set { d.set(newValue, forKey: Key.language.rawValue) }
    }
    var autoAsk: Bool {
        get { d.bool(forKey: Key.autoAsk.rawValue) }
        set { d.set(newValue, forKey: Key.autoAsk.rawValue) }
    }
    var customSocketPath: String {
        get { d.string(forKey: Key.customSocketPath.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.customSocketPath.rawValue) }
    }

    // MARK: - 流水线
    var autoFinal: Bool {
        get { d.bool(forKey: Key.autoFinal.rawValue) }
        set { d.set(newValue, forKey: Key.autoFinal.rawValue) }
    }
    var lineLen: Int {
        get { d.integer(forKey: Key.lineLen.rawValue) }
        set { d.set(newValue, forKey: Key.lineLen.rawValue) }
    }
    var batchSize: Int {
        get { d.integer(forKey: Key.batchSize.rawValue) }
        set { d.set(newValue, forKey: Key.batchSize.rawValue) }
    }
    var maxConcurrent: Int {
        get { max(1, d.integer(forKey: Key.maxConcurrent.rawValue)) }
        set { d.set(newValue, forKey: Key.maxConcurrent.rawValue) }
    }

    // MARK: - 模型
    var modelsDir: URL {
        get {
            if let p = d.string(forKey: Key.modelsDir.rawValue), !p.isEmpty { return URL(fileURLWithPath: p) }
            return Paths.defaultModelsDir
        }
        set { d.set(newValue.path, forKey: Key.modelsDir.rawValue) }
    }
    var draftModelFile: String {
        get { d.string(forKey: Key.draftModelFile.rawValue) ?? "ggml-large-v3-turbo.bin" }
        set { d.set(newValue, forKey: Key.draftModelFile.rawValue) }
    }
    var finalModelFile: String {
        get { d.string(forKey: Key.finalModelFile.rawValue) ?? "ggml-large-v3.bin" }
        set { d.set(newValue, forKey: Key.finalModelFile.rawValue) }
    }
    var vadModelFile: String {
        get { d.string(forKey: Key.vadModelFile.rawValue) ?? "ggml-silero-v5.1.2.bin" }
        set { d.set(newValue, forKey: Key.vadModelFile.rawValue) }
    }
    var draftModelURL: URL { modelsDir.appendingPathComponent(draftModelFile) }
    var finalModelURL: URL { modelsDir.appendingPathComponent(finalModelFile) }
    var vadModelURL: URL { modelsDir.appendingPathComponent(vadModelFile) }

    // MARK: - 翻译
    var translationKind: TranslationKind {
        get { TranslationKind(rawValue: d.string(forKey: Key.translationKind.rawValue) ?? "") ?? .ollama }
        set { d.set(newValue.rawValue, forKey: Key.translationKind.rawValue) }
    }
    var ollamaURL: String {
        get { d.string(forKey: Key.ollamaURL.rawValue) ?? "http://127.0.0.1:11434" }
        set { d.set(newValue, forKey: Key.ollamaURL.rawValue) }
    }
    var ollamaDraftModel: String {
        get { d.string(forKey: Key.ollamaDraftModel.rawValue) ?? "qwen2.5:7b" }
        set { d.set(newValue, forKey: Key.ollamaDraftModel.rawValue) }
    }
    var ollamaFinalModel: String {
        get { d.string(forKey: Key.ollamaFinalModel.rawValue) ?? "qwen3.8:27b-mlx" }
        set { d.set(newValue, forKey: Key.ollamaFinalModel.rawValue) }
    }
    var openAIBaseURL: String {
        get { d.string(forKey: Key.openAIBaseURL.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.openAIBaseURL.rawValue) }
    }
    var openAIAPIKey: String {
        get { d.string(forKey: Key.openAIAPIKey.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.openAIAPIKey.rawValue) }
    }
    var openAIModel: String {
        get { d.string(forKey: Key.openAIModel.rawValue) ?? "" }
        set { d.set(newValue, forKey: Key.openAIModel.rawValue) }
    }

    // MARK: - 输出

    /// 复制到视频目录的成品；工作区始终保留全部种类。至少保留一种，避免成品完全不可见。
    var exportKinds: Set<OutputKind> {
        get {
            let raw = d.stringArray(forKey: Key.exportOutputs.rawValue) ?? []
            let set = Set(raw.compactMap(OutputKind.init(rawValue:)))
            return set.isEmpty ? OutputKind.defaults : set
        }
        set {
            let normalized = newValue.isEmpty ? OutputKind.defaults : newValue
            d.set(OutputKind.allCases.filter { normalized.contains($0) }.map(\.rawValue),
                  forKey: Key.exportOutputs.rawValue)
        }
    }

    // MARK: - 引导
    var hasCompletedSetup: Bool {
        get { d.bool(forKey: Key.hasCompletedSetup.rawValue) }
        set { d.set(newValue, forKey: Key.hasCompletedSetup.rawValue) }
    }
}
