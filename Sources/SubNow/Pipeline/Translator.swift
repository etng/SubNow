import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Provider 协议（与具体服务无关：与具体服务解耦）

protocol TranslatorProvider {
    var label: String { get }
    /// 把一批行翻译成简体中文；返回 {行号: 译文}。行号是全局 id。
    func translateBatch(ids: [Int], lines: [String],
                        context: [(String, String)],   // (原文, 已译文)
                        sourceLanguageName: String,
                        lineLen: Int) async throws -> [Int: String]
}

// MARK: - 提示词（POC 调研结果 system prompt 原文照搬）

enum Prompts {
    static func system(_ sourceLanguageName: String, lineLen: Int) -> String {
        """
        你是专业的影视字幕翻译，负责把\(sourceLanguageName)字幕翻译成自然的简体中文。要求：
        1. 口语化、简洁，符合中文观影习惯；每行译文控制在 \(lineLen) 个汉字以内，宁短勿长，超出就精简；只输出一行，不要换行。
        2. 忠实原意，语气和说话人风格保持一致；不要解释、不要注释、不要保留原文。
        3. 人名、称呼、术语前后一致；结合上下文正确使用代词和省略。
        4. 严格按给定 JSON schema 输出，覆盖输入的每一行，行号一一对应，不增不删。
        """
    }

    static func user(context: [(String, String)], batch: [(Int, String)],
                     sourceLanguageName: String, missingIds: [Int] = []) -> String {
        var parts: [String] = []
        if !context.isEmpty {
            parts.append("【上文已有译文，仅供保持连贯，不要翻译或复述】")
            for (src, zh) in context {
                parts.append(src)
                parts.append("→ \(zh)")
            }
            parts.append("")
        }
        parts.append("【请把下面 \(batch.count) 行\(sourceLanguageName)字幕翻译成简体中文】")
        for (id, line) in batch {
            parts.append("\(id): \(line)")
        }
        if !missingIds.isEmpty {
            let preview = missingIds.prefix(8).map(String.init).joined(separator: " ")
            parts.append("注意：上次输出缺少行 \(preview)，这次必须补全。")
        }
        parts.append("")
        parts.append("只输出 JSON，格式 {\"translations\":[{\"id\":行号,\"zh\":\"译文\"}]}，每行都要有。")
        return parts.joined(separator: "\n")
    }

    /// schema（Ollama format 用）
    static let ollamaSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "translations": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "id": ["type": "integer"],
                        "zh": ["type": "string"],
                    ],
                    "required": ["id", "zh"],
                ],
            ]
        ],
        "required": ["translations"],
    ]

    /// 解析模型输出 → {id: 译文}；容错：截取首尾大括号之间
    static func parseTranslations(_ text: String) -> [Int: String] {
        var t = text
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}") {
            t = String(t[start...end])
        }
        guard let data = t.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = obj["translations"] as? [[String: Any]] else {
            return [:]
        }
        var result: [Int: String] = [:]
        for item in translations {
            guard let id = item["id"] as? Int, let zh = item["zh"] as? String else { continue }
            let cleaned = zh.replacingOccurrences(of: "<think>[\\s\\S]*?</think>", with: "",
                                                  options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleaned.isEmpty { result[id] = cleaned }
        }
        return result
    }
}

// MARK: - Ollama Provider

struct OllamaProvider: TranslatorProvider {
    let label = "Ollama"
    let baseURL: String
    let model: String

    struct OllamaError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func translateBatch(ids: [Int], lines: [String], context: [(String, String)],
                        sourceLanguageName: String, lineLen: Int) async throws -> [Int: String] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": Prompts.system(sourceLanguageName, lineLen: lineLen)],
                ["role": "user", "content": Prompts.user(context: context,
                                                         batch: Array(zip(ids, lines)),
                                                         sourceLanguageName: sourceLanguageName)],
            ],
            "stream": false,
            "keep_alive": "12h",
            "think": false,
            "options": ["temperature": 0.2, "num_ctx": 8192],
            "format": Prompts.ollamaSchema,
        ]
        // 单行兜底时精简 prompt（与POC 调研结果一致：只发这一行）
        if lines.count == 1 && context.isEmpty {
            body["messages"] = [
                ["role": "user", "content":
                    "\(lines[0])\n\n只输出 JSON：{\"translations\":[{\"id\":\(ids[0]),\"zh\":\"译文\"}]}"],
            ]
            body.removeValue(forKey: "format")
        }

        var request = URLRequest(url: try Self.chatURL(baseURL), timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaError(message: "Ollama 响应解析失败")
        }
        if let error = obj["error"] as? String {
            throw OllamaError(message: error)
        }
        guard let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw OllamaError(message: "Ollama 响应缺少 message.content")
        }
        return Prompts.parseTranslations(content)
    }

    static func chatURL(_ base: String) throws -> URL {
        guard let url = URL(string: base.trimmingCharacters(in: .whitespaces) + "/api/chat") else {
            throw OllamaError(message: "Ollama 地址无效")
        }
        return url
    }
}

// MARK: - OpenAI 兼容 Provider

struct OpenAICompatibleProvider: TranslatorProvider {
    let label = "OpenAI 兼容 API"
    let baseURL: String   // 形如 https://api.example.com/v1
    let apiKey: String
    let model: String

    struct APIError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    func translateBatch(ids: [Int], lines: [String], context: [(String, String)],
                        sourceLanguageName: String, lineLen: Int) async throws -> [Int: String] {
        var body: [String: Any] = [
            "model": model,
            "temperature": 0.2,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": Prompts.system(sourceLanguageName, lineLen: lineLen)],
                ["role": "user", "content": Prompts.user(context: context,
                                                         batch: Array(zip(ids, lines)),
                                                         sourceLanguageName: sourceLanguageName)],
            ],
        ]
        if lines.count == 1 && context.isEmpty {
            body["messages"] = [
                ["role": "user", "content":
                    "\(lines[0])\n\n只输出 JSON：{\"translations\":[{\"id\":\(ids[0]),\"zh\":\"译文\"}]}"],
            ]
        }

        var base = baseURL.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        if !base.hasSuffix("/chat/completions") { base += "/chat/completions" }
        guard let url = URL(string: base) else {
            throw APIError(message: "API 地址无效")
        }
        var request = URLRequest(url: url, timeoutInterval: 300)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(message: "非 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            let snippet = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw APIError(message: "API \(http.statusCode)：\(snippet)")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw APIError(message: "API 响应格式不符")
        }
        return Prompts.parseTranslations(content)
    }
}

// MARK: - 不翻译 Provider

struct NoneProvider: TranslatorProvider {
    let label = "不翻译"

    func translateBatch(ids: [Int], lines: [String], context: [(String, String)],
                        sourceLanguageName: String, lineLen: Int) async throws -> [Int: String] {
        Dictionary(uniqueKeysWithValues: zip(ids, lines))
    }
}

// MARK: - 批处理框架（重试/逐行兜底/上下文——与POC 调研结果策略一致）

final class Translator {
    let provider: TranslatorProvider

    init(provider: TranslatorProvider) {
        self.provider = provider
    }

    @MainActor
    static func make() -> Translator {
        let cfg = Config.shared
        let provider: TranslatorProvider
        switch cfg.translationKind {
        case .ollama:
            provider = OllamaProvider(baseURL: cfg.ollamaURL, model: cfg.ollamaDraftModel)
        case .openAICompatible:
            provider = OpenAICompatibleProvider(baseURL: cfg.openAIBaseURL,
                                                apiKey: cfg.openAIAPIKey, model: cfg.openAIModel)
        case .appleFM:
            if #available(macOS 26, *) {
                provider = AppleFMProvider()
            } else {
                provider = NoneProvider()
            }
        case .none:
            provider = NoneProvider()
        }
        return Translator(provider: provider)
    }

    @MainActor
    static func makeFinal() -> Translator {
        let cfg = Config.shared
        switch cfg.translationKind {
        case .ollama:
            return Translator(provider: OllamaProvider(baseURL: cfg.ollamaURL, model: cfg.ollamaFinalModel))
        case .openAICompatible:
            return Translator(provider: OpenAICompatibleProvider(baseURL: cfg.openAIBaseURL,
                                                                 apiKey: cfg.openAIAPIKey, model: cfg.openAIModel))
        default:
            return make()
        }
    }

    /// 全量翻译：30 行/批、前 2 行上下文、每批 3 次重试（缺行补发提示）、再失败逐行兜底；
    /// 仍失败的行保留原文。onBatch(batchesDone, batchesTotal)。
    @MainActor
    func translate(segments: [Segment], language: String, lineLen: Int,
                   onBatch: ((Int, Int) -> Void)?,
                   isCancelled: @escaping () -> Bool) async throws -> [Int: String] {
        let langName = Segments.langName(language == "orig" ? "" : language)
        let pending = segments.indices.filter { (segments[$0].zh ?? "").isEmpty }
        guard !pending.isEmpty else { return [:] }

        let batchSize = max(5, Config.shared.batchSize)
        let batches = stride(from: 0, to: pending.count, by: batchSize).map {
            Array(pending[$0..<min($0 + batchSize, pending.count)])
        }
        let total = batches.count
        var results: [Int: String] = [:]

        for (done, batchIdxs) in batches.enumerated() {
            try Task.checkCancellation()
            guard !isCancelled() else { throw CancellationError() }

            // 上下文：紧邻批前的 2 条已译段
            var context: [(String, String)] = []
            let first = batchIdxs[0]
            for i in max(0, first - 2)..<first where !(segments[i].zh ?? "").isEmpty {
                context.append((segments[i].src, segments[i].zh!))
            }

            let batchPairs = batchIdxs.map { ($0, segments[$0].src) }
            var missing = batchIdxs
            var attempt = 0
            while attempt < 3 {
                try Task.checkCancellation()
                let idLines = attempt == 0
                    ? batchPairs
                    : batchPairs.filter { missing.contains($0.0) }
                let promptMissing = attempt == 0 ? [] : missing
                do {
                    let got = try await provider.translateBatch(
                        ids: idLines.map(\.0), lines: idLines.map(\.1),
                        context: context, sourceLanguageName: langName, lineLen: lineLen)
                    for (id, zh) in got where batchIdxs.contains(id) {
                        results[id] = zh
                    }
                    missing = batchIdxs.filter { (results[$0] ?? "").isEmpty }
                    if missing.isEmpty { break }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.warn("翻译批 \(done + 1)/\(total) 第 \(attempt + 1) 次失败：\(error.localizedDescription)")
                }
                attempt += 1
                if !missing.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000_000) }
            }

            // 逐行兜底
            for id in missing {
                try Task.checkCancellation()
                do {
                    let got = try await provider.translateBatch(
                        ids: [id], lines: [segments[id].src], context: [],
                        sourceLanguageName: langName, lineLen: lineLen)
                    if let zh = got[id], !zh.isEmpty { results[id] = zh }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    Log.warn("逐行兜底失败 id=\(id)：\(error.localizedDescription)")
                }
            }

            onBatch?(done + 1, total)
        }
        return results
    }
}

// MARK: - Apple 系统模型 Provider（macOS 26+，Foundation Models）

@available(macOS 26, *)
struct AppleFMProvider: TranslatorProvider {
    let label = "Apple 系统模型"

    func translateBatch(ids: [Int], lines: [String], context: [(String, String)],
                        sourceLanguageName: String, lineLen: Int) async throws -> [Int: String] {
        let session = LanguageModelSession(model: SystemLanguageModel.default)
        let prompt = Prompts.user(context: context, batch: Array(zip(ids, lines)),
                                  sourceLanguageName: sourceLanguageName)
        let options = GenerationOptions(temperature: 0.2)
        let response = try await session.respond(to: prompt, options: options)
        return Prompts.parseTranslations(response.content)
    }
}
