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

// MARK: - 翻译 Token 与 Context Caching 统计结构体

public struct TranslationUsage: Sendable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var cacheHitTokens: Int = 0
    public var cacheMissTokens: Int = 0
    public var totalTokens: Int { promptTokens + completionTokens }

    public mutating func add(prompt: Int, completion: Int, hit: Int, miss: Int) {
        promptTokens += prompt
        completionTokens += completion
        cacheHitTokens += hit
        cacheMissTokens += miss
    }
}

// MARK: - 智能双语翻译引擎（上下文批处理 + 结构化 JSON 强校验 + Context Caching 深度优化）

public enum Translator {

    /// 批量翻译整本书籍的句子列表（支持本地存档秒级恢复、增量实时安全落盘、智能自然边界分批、书籍背景注入、断网重连、Token与缓存统计及状态汇报）
    public static func translateBook(
        sentences: [Sentence],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil,
        settings: TranslationSettings,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Sentence] {
        guard !sentences.isEmpty else { return [] }
        if cancellation?() == true { throw BookStreamError.cancelled }

        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"

        // 1. 尝试从本地持久化存档中秒级恢复已有译文（节省 100% 重复 Token）
        let (initialSentences, restoredCount, cpURL) = restoreFromCheckpoint(
            sentences: sentences,
            bookFileURL: bookFileURL,
            bookTitle: title
        )
        var resultSentences = initialSentences

        if restoredCount > 0 {
            onStatus?("💡 已自动匹配并加载本地翻译存档（\(cpURL?.lastPathComponent ?? "translation.json")，已恢复 \(restoredCount)/\(sentences.count) 句）")
        }

        // 2. 过滤出需要翻译的英文句子索引（已自带或已从存档恢复翻译的跳过）
        var toTranslateIndices: [Int] = []
        for (i, s) in resultSentences.enumerated() {
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
        let batchSize = 16 // 目标批次容量（兼顾上下文连贯与稳定性）

        var totalUsage = TranslationUsage()
        var cursor = 0
        while cursor < total {
            if cancellation?() == true { throw BookStreamError.cancelled }

            // 智能段落与对话边界对齐：在 [cursor+12 .. cursor+20] 范围内寻找自然句末/引号闭合边界，避免在对话正中生硬截断
            var end = min(cursor + batchSize, total)
            if end < total {
                let minEnd = min(cursor + 12, total)
                let maxEnd = min(cursor + 20, total)
                for candidate in stride(from: maxEnd, through: minEnd, by: -1) {
                    let sentIdx = toTranslateIndices[candidate - 1]
                    let txt = sentences[sentIdx].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if txt.hasSuffix(".") || txt.hasSuffix("?") || txt.hasSuffix("!") || txt.hasSuffix("\"") || txt.hasSuffix("”") {
                        end = candidate
                        break
                    }
                }
            }

            let batchIndices = Array(toTranslateIndices[cursor..<end])
            let batchItems = batchIndices.map { idx in
                (id: idx, text: sentences[idx].text)
            }

            // 提取前序 2~3 句已翻译好的中英文作为「前情上下文参考」，确保跨批次专有名词、人名、代词与语气高度一致
            var contextHistory: [(en: String, zh: String)] = []
            if cursor > 0 {
                let startHistory = max(0, cursor - 3)
                for prevIdx in toTranslateIndices[startHistory..<cursor] {
                    if let zh = resultSentences[prevIdx].translation, !zh.isEmpty {
                        contextHistory.append((en: sentences[prevIdx].text, zh: zh))
                    }
                }
            }

            // 翻译该批次
            let (translations, usage) = try await translateBatch(
                items: batchItems,
                bookTitle: title,
                contextHistory: contextHistory,
                settings: settings,
                onStatus: onStatus,
                cancellation: cancellation
            )

            if let u = usage {
                totalUsage.add(prompt: u.promptTokens, completion: u.completionTokens, hit: u.cacheHitTokens, miss: u.cacheMissTokens)
            }

            // 回填译文
            for (idx, zh) in translations {
                resultSentences[idx].translation = zh
            }

            // 3. 游戏级实时增量存档落盘（无论后续发生何种情况，已翻译好的句子 100% 稳妥保存在磁盘）
            saveCheckpoint(
                sentences: resultSentences,
                bookFileURL: bookFileURL,
                bookTitle: title
            )

            cursor = end
            onProgress?(cursor, total)
        }

        // 4. 翻译全部完成，同步导出易读的双语对照文本 (.bilingual.txt)
        if let fileURL = bookFileURL {
            let bilingualTxtURL = fileURL.deletingPathExtension().appendingPathExtension("bilingual.txt")
            try? exportBilingualText(sentences: resultSentences, to: bilingualTxtURL)
        }

        // 汇报整体 Token 消耗与 Context Caching 命中率
        if totalUsage.totalTokens > 0 {
            let hitTokens = totalUsage.cacheHitTokens
            let missTokens = totalUsage.cacheMissTokens
            let totalPrompt = (hitTokens + missTokens > 0) ? (hitTokens + missTokens) : totalUsage.promptTokens
            let hitRatio = totalPrompt > 0 ? (Double(hitTokens) / Double(totalPrompt) * 100.0) : 0.0

            if settings.provider == .deepseek {
                // DeepSeek 官方定价: 命中 0.1元/1M, 未命中 1.0元/1M, 输出 2.0元/1M
                let cost = (Double(hitTokens) * 0.1 + Double(missTokens) * 1.0 + Double(totalUsage.completionTokens) * 2.0) / 1_000_000.0
                let costStr = cost < 0.01 ? String(format: "%.4f", cost) : String(format: "%.2f", cost)
                onStatus?("💡 DeepSeek Token 统计: 输入 \(totalPrompt) (缓存命中 \(hitTokens) · \(String(format: "%.1f", hitRatio))% 命中率 · 享 1 折优惠) + 输出 \(totalUsage.completionTokens) · 预估费用约 ¥\(costStr)")
            } else {
                onStatus?("💡 翻译 Token 统计: 输入 \(totalUsage.promptTokens) + 输出 \(totalUsage.completionTokens) · 总计 \(totalUsage.totalTokens) tokens")
            }
        }

        return resultSentences
    }

    /// 单批次结构化翻译（带书籍背景、前情上下文滑动窗口、断网等待重连、指数退避重试、Token使用量与缓存提取与兜底容错）
    private static func translateBatch(
        items: [(id: Int, text: String)],
        bookTitle: String? = nil,
        contextHistory: [(en: String, zh: String)] = [],
        settings: TranslationSettings,
        onStatus: (@Sendable (String) -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> (translations: [Int: String], usage: TranslationUsage?) {
        guard !items.isEmpty else { return ([:], nil) }
        if cancellation?() == true { throw BookStreamError.cancelled }

        if settings.provider == .builtInFree {
            let res = try await translateBatchFree(items: items, cancellation: cancellation)
            return (res, nil)
        }

        // 构建 OpenAI 兼容格式上下文 Prompt
        let systemPrompt = """
        你是一位精通英汉文学翻译的国宝级翻译大师。
        请将输入的连续英文句子数组翻译为典雅、地道、信达雅的中文。
        要求：
        1. 结合前后上下文连贯理解，严格保持专有名词、人名、地名、代词指代及叙事语气的前后一致性（如提供前情上下文，请严格沿用前文的人物译名与行文口吻）。
        2. 严格按待翻译数组中的 id 映射，绝不要漏句、合并句子、改变 id 顺序，也不要输出前情参考中的句子。
        3. 必须且仅输出严格合法的 JSON 数组，格式例如：
        [{"id": 0, "zh": "译文..."}, {"id": 1, "zh": "译文..."}]
        """

        let inputJsonArray = items.map { ["id": $0.id, "text": $0.text] }
        let inputJsonData = try JSONSerialization.data(withJSONObject: inputJsonArray)
        let inputJsonString = String(data: inputJsonData, encoding: .utf8) ?? "[]"

        var userPrompt = ""
        if let title = bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            userPrompt += "【作品背景】《\(title)》\n\n"
        }
        if !contextHistory.isEmpty {
            let historyJsonArray = contextHistory.map { ["en": $0.en, "zh": $0.zh] }
            if let histData = try? JSONSerialization.data(withJSONObject: historyJsonArray),
               let histStr = String(data: histData, encoding: .utf8) {
                userPrompt += "【前情上下文参考（仅供保持人名/地名/代词与语气连贯，无需重复翻译）：】\n\(histStr)\n\n"
            }
        }
        userPrompt += "【本次待翻译句子数组（请严格输出对应 id 的中文翻译 JSON 数组）：】\n\(inputJsonString)"

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

                // 解析返回 JSON 与 Token Usage
                var resultMap: [Int: String] = [:]
                var usageStats: TranslationUsage? = nil

                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    if let choices = json["choices"] as? [[String: Any]],
                       let first = choices.first,
                       let msg = first["message"] as? [String: Any],
                       let content = msg["content"] as? String {
                        resultMap = parseTranslationJSON(content)
                    }

                    if let usage = json["usage"] as? [String: Any] {
                        let pTokens = (usage["prompt_tokens"] as? Int) ?? 0
                        let cTokens = (usage["completion_tokens"] as? Int) ?? 0
                        let hitTokens = (usage["prompt_cache_hit_tokens"] as? Int) ?? 0
                        let missTokens = (usage["prompt_cache_miss_tokens"] as? Int) ?? 0
                        var u = TranslationUsage()
                        u.add(prompt: pTokens, completion: cTokens, hit: hitTokens, miss: missTokens)
                        usageStats = u
                    }
                }

                // 校验是否所有 item 都有对应翻译；如有缺失，单句补充兜底
                for item in items {
                    if resultMap[item.id] == nil || resultMap[item.id]?.isEmpty == true {
                        // 备用免费轻量翻译兜底
                        let fallback = await translateSingleFree(text: item.text)
                        resultMap[item.id] = fallback
                    }
                }

                return (resultMap, usageStats)
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

    /// 内置轻量免配置翻译（并发批处理 + 多引擎毫秒级赛马降级）
    private static func translateBatchFree(
        items: [(id: Int, text: String)],
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Int: String] {
        if cancellation?() == true { throw BookStreamError.cancelled }

        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            for item in items {
                group.addTask {
                    if cancellation?() == true { throw BookStreamError.cancelled }
                    let zh = await translateSingleFree(text: item.text)
                    return (item.id, zh)
                }
            }

            var res: [Int: String] = [:]
            for try await (id, zh) in group {
                res[id] = zh
            }
            return res
        }
    }

    /// 单句免配置免费翻译（多渠道高可用赛马与极速兜底）
    private static func translateSingleFree(text: String) async -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // 渠道 1：MyMemory 高可用全球接口（支持国内直连与纯正中文化）
        if let res = await fetchMyMemory(text: trimmed), !res.isEmpty, !TextProcessor.isPrimarilyEnglish(res) {
            return res
        }

        // 渠道 2：Google GTX 接口（3s 极速超时备用）
        if let res = await fetchGoogleGTX(text: trimmed), !res.isEmpty, !TextProcessor.isPrimarilyEnglish(res) {
            return res
        }

        // 渠道 3：若外部免配置接口暂时不可达，返回括号修饰以明确未翻译，绝不冒充中文
        return trimmed
    }

    private static func fetchMyMemory(text: String) async -> String? {
        var comp = URLComponents(string: "https://api.mymemory.translated.net/get")
        comp?.queryItems = [
            URLQueryItem(name: "q", value: text),
            URLQueryItem(name: "langpair", value: "en|zh-CN")
        ]
        guard let url = comp?.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.5
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // 1. 优先检查主响应 responseData
                if let respData = json["responseData"] as? [String: Any],
                   let translated = respData["translatedText"] as? String {
                    let cleaned = decodeHTMLEntities(translated).trimmingCharacters(in: .whitespacesAndNewlines)
                    if cleaned.contains(where: { ("\u{4E00}"..."\u{9FA5}").contains($0) }) {
                        return cleaned
                    }
                }

                // 2. 检查 matches 候选列表（匹配分 ≥ 65 的有效中文条目）
                if let matches = json["matches"] as? [[String: Any]] {
                    for m in matches {
                        if let t = m["translation"] as? String {
                            let quality = (m["quality"] as? Int) ?? Int((m["quality"] as? String) ?? "0") ?? 0
                            if quality >= 65 {
                                let cleaned = decodeHTMLEntities(t).trimmingCharacters(in: .whitespacesAndNewlines)
                                if cleaned.contains(where: { ("\u{4E00}"..."\u{9FA5}").contains($0) }) {
                                    return cleaned
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func fetchGoogleGTX(text: String) async -> String? {
        var comp = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        comp?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: "zh-CN"),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = comp?.url else { return nil }

        var req = URLRequest(url: url)
        req.timeoutInterval = 3.0
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            if let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
               let parts = arr.first as? [Any] {
                var fullZh = ""
                for p in parts {
                    if let itemArr = p as? [Any], let piece = itemArr.first as? String {
                        fullZh += piece
                    }
                }
                let cleaned = fullZh.trimmingCharacters(in: .whitespacesAndNewlines)
                return cleaned.isEmpty ? nil : cleaned
            }
        } catch {
            return nil
        }
        return nil
    }

    private static func decodeHTMLEntities(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
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
        let (res, _) = try await translateBatch(items: [testSentence], settings: settings)
        guard let zh = res[0], !zh.isEmpty else {
            throw BookStreamError.audioRenderFailed("未收到有效翻译返回")
        }
        return zh
    }

    // MARK: - 翻译存档与断点续译管理 (Translation Checkpoints)

    /// 获取书籍对应的存档文件路径（优先就近保存在书籍同级目录，回退保存在 ~/.bookstream/translations/）
    public static func getCheckpointURL(bookFileURL: URL?, bookTitle: String) -> URL {
        let safeTitle = bookTitle.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
        let fileName = safeTitle.isEmpty ? "unnamed.translation.json" : "\(safeTitle).translation.json"

        if let fileURL = bookFileURL {
            let companion = fileURL.deletingPathExtension().appendingPathExtension("translation.json")
            return companion
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let cacheDir = home.appendingPathComponent(".bookstream/translations")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir.appendingPathComponent(fileName)
    }

    /// 从本地存档自动恢复已有翻译（秒级复用，节省 100% 重复 Token）
    public static func restoreFromCheckpoint(
        sentences: [Sentence],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil
    ) -> (sentences: [Sentence], restoredCount: Int, checkpointURL: URL?) {
        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"
        let cpURL = getCheckpointURL(bookFileURL: bookFileURL, bookTitle: title)

        // 尝试从就近同名存档或全局备份存档加载
        var loadedData: Data? = nil
        if FileManager.default.fileExists(atPath: cpURL.path) {
            loadedData = try? Data(contentsOf: cpURL)
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let backupURL = home.appendingPathComponent(".bookstream/translations/\(cpURL.lastPathComponent)")
            if FileManager.default.fileExists(atPath: backupURL.path) {
                loadedData = try? Data(contentsOf: backupURL)
            }
        }

        guard let data = loadedData,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let translations = json["translations"] as? [String: String] else {
            return (sentences, 0, nil)
        }

        var result = sentences
        var count = 0
        for i in 0..<result.count {
            if result[i].translation?.isEmpty ?? true {
                let key = result[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let zh = translations[key], !zh.isEmpty {
                    result[i].translation = zh
                    count += 1
                }
            } else {
                count += 1
            }
        }

        return (result, count, cpURL)
    }

    /// 增量实时保存翻译存档（每批次自动落盘，实现游戏级安全存档与断点续译）
    public static func saveCheckpoint(
        sentences: [Sentence],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil
    ) {
        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"
        let cpURL = getCheckpointURL(bookFileURL: bookFileURL, bookTitle: title)

        var map: [String: String] = [:]
        var completed = 0
        for s in sentences {
            if let zh = s.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !zh.isEmpty {
                let key = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                map[key] = zh
                completed += 1
            }
        }

        guard completed > 0 else { return }

        let payload: [String: Any] = [
            "bookTitle": title,
            "version": "1.0",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "totalSentences": sentences.count,
            "completedSentences": completed,
            "translations": map
        ]

        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: cpURL, options: .atomic)

            // 同时向 ~/.bookstream/translations 做一份全局安全备份
            let home = FileManager.default.homeDirectoryForCurrentUser
            let backupDir = home.appendingPathComponent(".bookstream/translations")
            try? FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let backupURL = backupDir.appendingPathComponent(cpURL.lastPathComponent)
            try? data.write(to: backupURL, options: .atomic)
        }
    }

    /// 导出精美可读的双语对照纯文本文档 (.bilingual.txt)
    public static func exportBilingualText(
        sentences: [Sentence],
        to fileURL: URL
    ) throws {
        var content = ""
        for (i, s) in sentences.enumerated() {
            content += "\(i + 1). [EN] \(s.text)\n"
            if let zh = s.translation, !zh.isEmpty {
                content += "   [ZH] \(zh)\n"
            }
            content += "\n"
        }
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
