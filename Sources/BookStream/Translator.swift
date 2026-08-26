import Foundation

// MARK: - 翻译服务商与配置

public enum TranslationProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case deepseek    = "deepseek"     // DeepSeek 官方 API（文学信达雅，性价比极高）
    case custom      = "custom"       // 本地 MLX (rapid-mlx) / 自定义端点 (OpenAI 兼容)
    case builtInFree = "builtInFree"  // 内置免配置轻量翻译 (无需 Key)

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .deepseek: return "DeepSeek 官方 API (推荐·文学典雅·信达雅)"
        case .custom: return "本地 MLX (rapid-mlx) / 自定义端点"
        case .builtInFree: return "内置免配置轻量翻译"
        }
    }

    public var defaultEndpoint: String {
        switch self {
        case .deepseek: return "https://api.deepseek.com"
        case .custom: return "http://127.0.0.1:8000"
        case .builtInFree: return ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .deepseek: return "deepseek-chat"
        case .custom: return "default"
        case .builtInFree: return "built-in"
        }
    }
}

public struct TranslationSettings: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var provider: TranslationProvider
    public var apiKey: String
    public var endpointURL: String
    public var model: String

    public static let `default` = TranslationSettings(
        enabled: false,
        provider: .deepseek,
        apiKey: "",
        endpointURL: TranslationProvider.deepseek.defaultEndpoint,
        model: TranslationProvider.deepseek.defaultModel
    )

    public init(
        enabled: Bool = false,
        provider: TranslationProvider = .deepseek,
        apiKey: String = "",
        endpointURL: String = "",
        model: String = ""
    ) {
        self.enabled = enabled
        self.provider = provider
        self.apiKey = apiKey
        self.endpointURL = endpointURL.isEmpty ? provider.defaultEndpoint : endpointURL
        self.model = model.isEmpty ? provider.defaultModel : model
    }
}

// MARK: - 智能双语翻译引擎（上下文批处理 + 结构化 JSON 强校验）

public enum Translator {

    /// 批量翻译整本书籍的句子列表（保持上下文连贯与严格 1-to-1 映射，支持断网重连与状态汇报）
    public static func translateBook(
        sentences: [Sentence],
        settings: TranslationSettings,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Sentence] {
        guard !sentences.isEmpty else { return [] }
        if cancellation?() == true { throw BookStreamError.cancelled }

        var resultSentences = sentences

        // 过滤出需要翻译的英文句子索引（已自带翻译的跳过）
        var toTranslateIndices: [Int] = []
        for (i, s) in sentences.enumerated() {
            let tr = s.translation?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if tr.isEmpty && TextProcessor.isPrimarilyEnglish(s.text) {
                toTranslateIndices.append(i)
            }
        }

        guard !toTranslateIndices.isEmpty else {
            // 所有句子已有中文翻译，直接返回
            return resultSentences
        }

        let total = toTranslateIndices.count
        let batchSize = 16 // 每次 16 句（既能保持充分的上下文连贯，又兼顾速度与稳定性）

        var cursor = 0
        while cursor < total {
            if cancellation?() == true { throw BookStreamError.cancelled }

            let end = min(cursor + batchSize, total)
            let batchIndices = Array(toTranslateIndices[cursor..<end])
            let batchItems = batchIndices.map { idx in
                (id: idx, text: sentences[idx].text)
            }

            // 翻译该批次
            let translations = try await translateBatch(
                items: batchItems,
                settings: settings,
                onStatus: onStatus,
                cancellation: cancellation
            )

            // 回填译文
            for (idx, zh) in translations {
                resultSentences[idx].translation = zh
            }

            cursor = end
            onProgress?(cursor, total)
        }

        return resultSentences
    }

    /// 单批次结构化翻译（带断网等待重连、指数退避重试与兜底容错）
    private static func translateBatch(
        items: [(id: Int, text: String)],
        settings: TranslationSettings,
        onStatus: (@Sendable (String) -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Int: String] {
        guard !items.isEmpty else { return [:] }
        if cancellation?() == true { throw BookStreamError.cancelled }

        if settings.provider == .builtInFree {
            return try await translateBatchFree(items: items, cancellation: cancellation)
        }

        // 构建 OpenAI 兼容格式上下文 Prompt
        let systemPrompt = """
        你是一位精通英汉文学翻译的国宝级翻译大师。
        请将输入的连续英文句子数组翻译为典雅、地道、信达雅的中文。
        要求：
        1. 结合前后上下文连贯理解，保持专有名词、人名、地名、代词的前后一致性。
        2. 严格按输入中的 id 映射，绝不要漏句、合并句子或改变 id 顺序。
        3. 必须且仅输出严格合法的 JSON 数组，格式例如：
        [{"id": 0, "zh": "译文..."}, {"id": 1, "zh": "译文..."}]
        """

        let inputJsonArray = items.map { ["id": $0.id, "text": $0.text] }
        let inputJsonData = try JSONSerialization.data(withJSONObject: inputJsonArray)
        let inputJsonString = String(data: inputJsonData, encoding: .utf8) ?? "[]"

        let userPrompt = "待翻译句子数组如下，请输出翻译 JSON 数组：\n\(inputJsonString)"

        var requestBody: [String: Any] = [
            "model": settings.model.isEmpty ? settings.provider.defaultModel : settings.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3
        ]
        if settings.provider == .deepseek {
            requestBody["response_format"] = ["type": "json_object"]
        }

        let rawEndpoint = settings.endpointURL.isEmpty ? settings.provider.defaultEndpoint : settings.endpointURL
        let resolvedEndpoint = normalizeEndpoint(rawEndpoint)
        guard let url = URL(string: resolvedEndpoint) else {
            throw BookStreamError.audioRenderFailed("无效的翻译 API 端点: \(rawEndpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        let maxRetries = 5
        var currentAttempt = 0
        var lastError: Error?

        while currentAttempt < maxRetries {
            if cancellation?() == true { throw BookStreamError.cancelled }
            currentAttempt += 1

            do {
                let (data, response) = try await sendRequest(request: request, cancellation: cancellation)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 || (http.statusCode >= 500 && http.statusCode <= 504) {
                        let delay = Double(currentAttempt) * 2.5
                        onStatus?("⚠︎ 翻译 API 繁忙/限流 (\(http.statusCode))，等待 \(String(format: "%.1f", delay))s 后自动重试 [\(currentAttempt)/\(maxRetries)]...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else if http.statusCode >= 400 {
                        let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        throw BookStreamError.audioRenderFailed("翻译 API 错误 (\(http.statusCode)): \(errStr.prefix(160))")
                    }
                }

                // 解析返回 JSON
                var resultMap: [Int: String] = [:]
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let first = choices.first,
                   let msg = first["message"] as? [String: Any],
                   let content = msg["content"] as? String {
                    resultMap = parseTranslationJSON(content)
                }

                // 校验是否所有 item 都有对应翻译；如有缺失，单句补充兜底
                for item in items {
                    if resultMap[item.id] == nil || resultMap[item.id]?.isEmpty == true {
                        // 备用免费轻量翻译兜底
                        let fallback = try await translateSingleFree(text: item.text)
                        resultMap[item.id] = fallback
                    }
                }

                return resultMap
            } catch {
                if cancellation?() == true || (error as? BookStreamError) == .cancelled {
                    throw BookStreamError.cancelled
                }
                lastError = error

                let nsErr = error as NSError
                let isNetworkDown = (nsErr.domain == NSURLErrorDomain && (
                    nsErr.code == NSURLErrorNotConnectedToInternet ||
                    nsErr.code == NSURLErrorNetworkConnectionLost ||
                    nsErr.code == NSURLErrorTimedOut ||
                    nsErr.code == NSURLErrorCannotConnectToHost ||
                    nsErr.code == NSURLErrorDNSLookupFailed ||
                    nsErr.code == NSURLErrorCannotFindHost
                ))

                if currentAttempt < maxRetries {
                    let delay = Double(currentAttempt) * 3.0
                    let reason = isNetworkDown ? "网络连接已中断 / 无法连接" : "请求异常 (\(error.localizedDescription))"
                    onStatus?("⚠︎ \(reason)，正在等待重连，\(String(format: "%.1f", delay))s 后自动重试 [\(currentAttempt)/\(maxRetries)]...")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                } else {
                    break
                }
            }
        }

        if let lastError {
            throw BookStreamError.audioRenderFailed("翻译网络重试已达上限: \(lastError.localizedDescription)")
        }
        throw BookStreamError.audioRenderFailed("翻译请求失败")
    }

    /// 内置轻量免配置翻译
    private static func translateBatchFree(
        items: [(id: Int, text: String)],
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Int: String] {
        var res: [Int: String] = [:]
        for item in items {
            if cancellation?() == true { throw BookStreamError.cancelled }
            res[item.id] = try await translateSingleFree(text: item.text)
        }
        return res
    }

    /// 单句免配置免费翻译（基于公开高可用轻量接口）
    private static func translateSingleFree(text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=zh-CN&dt=t&q=\(encoded)") else {
            return trimmed
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let parts = arr.first as? [Any] {
                var fullZh = ""
                for p in parts {
                    if let itemArr = p as? [Any], let piece = itemArr.first as? String {
                        fullZh += piece
                    }
                }
                if !fullZh.isEmpty { return fullZh }
            }
        } catch {
            // 忽略网络抖动，返回原文防崩溃
        }
        return trimmed
    }

    /// 解析 LLM 返回的 JSON 字符串（支持数组或包在键中的对象）
    private static func parseTranslationJSON(_ content: String) -> [Int: String] {
        var map: [Int: String] = [:]
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return map }

        if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in list {
                if let id = obj["id"] as? Int, let zh = (obj["zh"] as? String) ?? (obj["translation"] as? String) {
                    map[id] = zh.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 兼容可能包在外层对象如 {"sentences": [...]} 或 {"translations": [...]}
            for (_, val) in dict {
                if let list = val as? [[String: Any]] {
                    for obj in list {
                        if let id = obj["id"] as? Int, let zh = (obj["zh"] as? String) ?? (obj["translation"] as? String) {
                            map[id] = zh.trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    }
                }
            }
        }
        return map
    }

    /// 发送可取消的网络请求
    private static func sendRequest(
        request: URLRequest,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> (Data, URLResponse) {
        final class TaskHolder: @unchecked Sendable {
            var task: URLSessionDataTask?
        }
        let holder = TaskHolder()

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.dataTask(with: request) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let data = data, let response = response {
                    continuation.resume(returning: (data, response))
                } else {
                    continuation.resume(throwing: BookStreamError.audioRenderFailed("未知网络错误"))
                }
            }
            holder.task = task
            task.resume()

            if cancellation?() == true {
                task.cancel()
                continuation.resume(throwing: BookStreamError.cancelled)
            }
        }
    }

    /// 智能将用户输入的 Base URL 或各种格式端点规范化为 OpenAI 兼容的 /chat/completions 完整路径
    public static func normalizeEndpoint(_ input: String) -> String {
        var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if !trimmed.hasPrefix("http://") && !trimmed.hasPrefix("https://") {
            trimmed = "http://" + trimmed
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        if trimmed.hasSuffix("/chat/completions") {
            return trimmed
        }
        if trimmed.hasSuffix("/v1") {
            return trimmed + "/chat/completions"
        }
        if trimmed.contains("api.deepseek.com") {
            return trimmed + "/chat/completions"
        }
        return trimmed + "/v1/chat/completions"
    }

    /// 测试连接与翻译质量
    public static func testConnection(settings: TranslationSettings) async throws -> String {
        let testSentence = (id: 0, text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.")
        let res = try await translateBatch(items: [testSentence], settings: settings)
        guard let zh = res[0], !zh.isEmpty else {
            throw BookStreamError.audioRenderFailed("未收到有效翻译返回")
        }
        return zh
    }
}
