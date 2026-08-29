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
    /// 是否关闭大模型思考模式。DeepSeek 官方文档：思考模式默认开启（deepseek-v4-flash 默认 effort=high），
    /// 纯翻译任务无需思维链，关闭后速度与稳定性显著提升（官方 API 通过 {"thinking": {"type": "disabled"}} 控制）。
    public var disableThinking: Bool
    /// 并发翻译批数。DeepSeek 官方 v4-flash 账号级并发上限 2500，官方端点建议 4~16；本地 MLX/自定义端点建议 1~2。
    public var concurrentRequests: Int

    public static let `default` = TranslationSettings(
        enabled: false,
        provider: .deepseek,
        apiKey: "",
        endpointURL: TranslationProvider.deepseek.defaultEndpoint,
        model: TranslationProvider.deepseek.defaultModel,
        disableThinking: true,
        concurrentRequests: 4
    )

    public init(
        enabled: Bool = false,
        provider: TranslationProvider = .deepseek,
        apiKey: String = "",
        endpointURL: String = "",
        model: String = "",
        disableThinking: Bool = true,
        concurrentRequests: Int = 4
    ) {
        self.enabled = enabled
        self.provider = provider
        self.apiKey = apiKey
        self.endpointURL = endpointURL.isEmpty ? provider.defaultEndpoint : endpointURL
        self.model = model.isEmpty ? provider.defaultModel : model
        self.disableThinking = disableThinking
        self.concurrentRequests = max(1, min(concurrentRequests, 32))
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, provider, apiKey, endpointURL, model, disableThinking, concurrentRequests
    }

    /// 向前兼容解码：旧版本存档缺少新增字段时使用默认值，避免解码失败导致用户设置被整体重置。
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = try c.decodeIfPresent(TranslationProvider.self, forKey: .provider) ?? .deepseek
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        let rawEndpoint = try c.decodeIfPresent(String.self, forKey: .endpointURL) ?? ""
        endpointURL = rawEndpoint.isEmpty ? provider.defaultEndpoint : rawEndpoint
        let rawModel = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        model = rawModel.isEmpty ? provider.defaultModel : rawModel
        disableThinking = try c.decodeIfPresent(Bool.self, forKey: .disableThinking) ?? true
        concurrentRequests = max(1, min(try c.decodeIfPresent(Int.self, forKey: .concurrentRequests) ?? 4, 32))
    }
}

// MARK: - 翻译 Token 与 Context Caching 统计结构体

public struct TranslationUsage: Sendable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var reasoningTokens: Int = 0
    public var cacheHitTokens: Int = 0
    public var cacheMissTokens: Int = 0
    public var totalTokens: Int { promptTokens + completionTokens }

    public mutating func add(prompt: Int, completion: Int, reasoning: Int = 0, hit: Int, miss: Int) {
        promptTokens += prompt
        completionTokens += completion
        reasoningTokens += reasoning
        cacheHitTokens += hit
        cacheMissTokens += miss
    }
}

// MARK: - 智能双语翻译引擎（上下文批处理 + 结构化 JSON 强校验 + Context Caching 深度优化）

/// 结构化单句翻译结果（支持 AI 意群双向对齐）
public struct TranslationResultItem: Sendable {
    public let id: Int
    public let zh: String
    public let splitEn: String?
    public let splitZh: String?

    public init(id: Int, zh: String, splitEn: String? = nil, splitZh: String? = nil) {
        self.id = id
        self.zh = zh
        self.splitEn = splitEn
        self.splitZh = splitZh
    }
}

// MARK: - 并发批处理基础设施

/// 单个翻译/拆句批次计划（含自然句末边界探测后的句组）
private struct BatchPlan: Sendable {
    let index: Int
    let startCursor: Int
    let items: [(id: Int, text: String)]
}

/// 单批次执行结果（译文 + Token 用量 + 兜底句数）
private struct BatchOutcome: Sendable {
    var translations: [Int: TranslationResultItem]
    var usage: TranslationUsage
    var fallbackCount: Int
}

/// 整本书翻译过程中的共享可变状态（Swift 6 严格并发下用锁保护的 @unchecked Sendable 容器）
private final class BookTranslationState: @unchecked Sendable {
    let lock = NSLock()
    var resultSentences: [Sentence]
    var allTranslationsMap: [Int: TranslationResultItem] = [:]
    var usage = TranslationUsage()
    var fallbackCount = 0
    let bookFileURL: URL?
    let title: String

    init(resultSentences: [Sentence], bookFileURL: URL?, title: String) {
        self.resultSentences = resultSentences
        self.bookFileURL = bookFileURL
        self.title = title
    }

    /// 合并一批结果并增量落盘（父侧串行调用，锁保护与子任务并发读取）
    func merge(_ outcome: BatchOutcome) {
        lock.lock()
        defer { lock.unlock() }
        for (idx, item) in outcome.translations {
            resultSentences[idx].translation = item.zh
            allTranslationsMap[idx] = item
        }
        usage.add(prompt: outcome.usage.promptTokens, completion: outcome.usage.completionTokens, reasoning: outcome.usage.reasoningTokens, hit: outcome.usage.cacheHitTokens, miss: outcome.usage.cacheMissTokens)
        fallbackCount += outcome.fallbackCount

        // 游戏级实时增量存档：原句 + 已产生的意群切分（绝不删除已有 Key）
        var currentSplits: [String: (en: String, zh: String)] = [:]
        for (idx, item) in allTranslationsMap {
            if let en = item.splitEn, let zh = item.splitZh {
                currentSplits[resultSentences[idx].text] = (en, zh)
            }
        }
        Translator.saveCheckpoint(
            sentences: resultSentences,
            splits: currentSplits,
            bookFileURL: bookFileURL,
            bookTitle: title
        )
    }
}

public enum Translator {

    /// 校验并执行中英双语意群无损对齐切分。
    /// 守门员：严格比对字母/数字序列，若大模型存在增删单词、篡改拼写或中英切分段数不匹配，则自动安全熔断返回 nil。
    public static func alignAndSplitSentence(
        originalText: String,
        splitEn: String,
        splitZh: String,
        pauseAfter: Double
    ) -> [Sentence]? {
        let normEn = splitEn.replacingOccurrences(of: "|", with: "｜")
        let normZh = splitZh.replacingOccurrences(of: "|", with: "｜")

        let enParts = normEn.components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let zhParts = normZh.components(separatedBy: "｜").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }

        guard enParts.count > 1, enParts.count == zhParts.count else { return nil }

        func wordsOnly(_ str: String) -> [String] {
            str.lowercased()
               .components(separatedBy: CharacterSet.alphanumerics.inverted)
               .filter { !$0.isEmpty }
        }

        let enWords = wordsOnly(enParts.joined(separator: " "))
        let origWords = wordsOnly(originalText)
        guard enWords == origWords else { return nil }

        // 防「语序重排错位」：英文与中文的第 k 个意群边界应位于全句相近的相对位置（阈值 17 个百分点）。
        // 实测《奥德赛》300 处拆句：对齐样本集中于 0~11pp，语序颠倒型错位（如 EN「flew up ｜ sat as a
        // swallow」/ ZH「化作燕子 ｜ 飞上椽木」）落在 18~24pp。取 17pp 一刀切：宁可保持整句不拆，
        // 绝不产出片段错位的双语字幕（错位字幕在成片中会造成英文与中文各说各话）。
        let enTotal = Double(max(normEn.count, 1))
        let zhTotal = Double(max(normZh.count, 1))
        for i in 0..<(enParts.count - 1) {
            let enPrefix = Double(enParts[0...i].joined(separator: " ").count)
            let zhPrefix = Double(zhParts[0...i].joined(separator: "").count)
            let enPct = enPrefix / enTotal * 100
            let zhPct = zhPrefix / zhTotal * 100
            if abs(enPct - zhPct) > 17 { return nil }
        }

        // 防畸形分隔符：首/尾/连续「｜」（如「…，｜」尾缀空片段）
        if normEn.hasPrefix("｜") || normEn.hasSuffix("｜") || normZh.hasPrefix("｜") || normZh.hasSuffix("｜") {
            return nil
        }
        if normEn.contains("｜｜") || normZh.contains("｜｜") { return nil }

        var result: [Sentence] = []
        for i in 0..<enParts.count {
            let pause = (i < enParts.count - 1) ? 0.4 : pauseAfter
            result.append(Sentence(id: i, text: enParts[i], translation: zhParts[i], pauseAfter: pause))
        }
        return result
    }

    /// 批量翻译整本书籍的句子列表（支持本地存档秒级恢复、增量实时安全落盘、横竖屏自适应意群切分、智能自然边界分批、书籍背景注入、断网重连、Token与缓存统计及状态汇报）
    public static func translateBook(
        sentences: [Sentence],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil,
        isPortrait: Bool = true,
        settings: TranslationSettings,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        onStatus: (@Sendable (String) -> Void)? = nil,
        pauseCheck: (@Sendable () async throws -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> [Sentence] {
        guard !sentences.isEmpty else { return [] }
        if cancellation?() == true || Task.isCancelled { throw BookStreamError.cancelled }
        try await pauseCheck?()

        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"

        // 1. 尝试从本地持久化存档中秒级恢复已有译文与意群切分（节省 100% 重复 Token）
        let (initialSentences, restoredCount, cpURL) = restoreFromCheckpoint(
            sentences: sentences,
            bookFileURL: bookFileURL,
            bookTitle: title
        )
        var resultSentences = initialSentences
        let restoredSplits = restoreSplitsFromCheckpoint(
            sentences: sentences,
            bookFileURL: bookFileURL,
            bookTitle: title
        )

        var allTranslationsMap: [Int: TranslationResultItem] = [:]
        for (i, s) in resultSentences.enumerated() {
            let key = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let zh = s.translation, !zh.isEmpty {
                if let sp = restoredSplits[key] {
                    allTranslationsMap[i] = TranslationResultItem(id: i, zh: zh, splitEn: sp.en, splitZh: sp.zh)
                } else {
                    allTranslationsMap[i] = TranslationResultItem(id: i, zh: zh)
                }
            }
        }

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
            // 所有句子已有中文翻译，直接执行意群切分并秒级返回（0 Token 消耗，直接进入音视频生成流程）
            var finalSentences: [Sentence] = []
            var aiSplitCount = 0
            for (idx, sent) in resultSentences.enumerated() {
                if let item = allTranslationsMap[idx],
                   let splitEn = item.splitEn, let splitZh = item.splitZh,
                   let subSentences = alignAndSplitSentence(originalText: sent.text, splitEn: splitEn, splitZh: splitZh, pauseAfter: sent.pauseAfter) {
                    finalSentences.append(contentsOf: subSentences)
                    aiSplitCount += 1
                } else {
                    var copy = sent
                    if let item = allTranslationsMap[idx] {
                        copy.translation = item.zh.replacingOccurrences(of: "｜", with: "").replacingOccurrences(of: "|", with: "")
                    }
                    finalSentences.append(copy)
                }
            }
            if aiSplitCount > 0 {
                let modeName = isPortrait ? "9:16竖屏自适应" : "16:9宽屏自适应"
                onStatus?("💡 AI 语义意群断句 (\(modeName)): 已秒级复用 \(aiSplitCount) 处长句对齐切分")
            }
            if let fileURL = bookFileURL {
                let bilingualTxtURL = fileURL.deletingPathExtension().appendingPathExtension("bilingual.txt")
                exportBilingualWithFallback(sentences: finalSentences, to: bilingualTxtURL, onStatus: onStatus)
            }
            return finalSentences
        }

        let total = toTranslateIndices.count
        let defaultBatchSize = 8 // 目标批次容量（兼顾上下文连贯、响应敏捷度与稳定性）

        let estimatedBatches = max(1, Int(ceil(Double(total) / Double(defaultBatchSize))))
        let modelName = settings.model.isEmpty ? settings.provider.defaultModel : settings.model
        let endpointName = settings.endpointURL.isEmpty ? settings.provider.defaultEndpoint : settings.endpointURL
        let concurrency = max(1, min(settings.concurrentRequests, estimatedBatches))
        let thinkingDesc = settings.disableThinking ? "已关闭（更快更稳）" : "开启（慢·纯翻译不推荐）"
        onStatus?("💡 启动双语翻译流水线: 待译 \(total) 句 · 规划约 \(estimatedBatches) 批次 · 并发 \(concurrency) 路 · 思考模式=\(thinkingDesc) · 模型=\(modelName) · 端点=\(endpointName)")

        // 构建批次计划（沿用自然句末/引号闭合边界探测，避免在对话正中生硬截断）
        var plans: [BatchPlan] = []
        var cursor = 0
        var planIndex = 0
        while cursor < total {
            planIndex += 1
            var end = min(cursor + defaultBatchSize, total)
            if end < total {
                let minEnd = min(cursor + 5, total)
                let maxEnd = min(cursor + 10, total)
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
            plans.append(BatchPlan(index: planIndex, startCursor: cursor, items: batchItems))
            cursor = end
        }

        let overallStartTime = Date()
        let state = BookTranslationState(resultSentences: resultSentences, bookFileURL: bookFileURL, title: title)
        // 将存档恢复的译文与意群切分种子灌入共享状态（保证恢复的拆句在组装阶段继续生效）
        state.lock.withLock {
            state.allTranslationsMap = allTranslationsMap
        }

        // 阶段一：并发批量翻译（纯翻译任务，不含拆句指令 → 任务更简单、更快、译文更稳）
        try await runConcurrentBatches(
            plans: plans,
            splitOnly: false,
            isPortrait: isPortrait,
            title: title,
            sentences: sentences,
            toTranslateIndices: toTranslateIndices,
            state: state,
            settings: settings,
            onStatus: onStatus,
            onProgress: onProgress,
            pauseCheck: pauseCheck,
            cancellation: cancellation
        )
        resultSentences = state.resultSentences

        if state.fallbackCount > 0 {
            onStatus?("⚠︎ 本次翻译共有 \(state.fallbackCount) 句在 LLM 补译重试后仍未成功，已用备用机翻通道兜底（日志含「备用通道」标记）。为保证最终字幕质量，建议导出后人工抽查这些句子的译文。")
        }

        // 阶段二：仅对超长句执行 AI 意群双向对齐拆句（短句 0 额外请求；拆句只插「｜」不重译，译文 100% 保持阶段一质量）
        let splitThreshold = isPortrait ? 80 : 150
        let longIndices = toTranslateIndices.filter { sentences[$0].text.count > splitThreshold }
        let splitsBefore = state.allTranslationsMap.values.filter { $0.splitEn != nil }.count
        if !longIndices.isEmpty {
            let modeName = isPortrait ? "9:16竖屏自适应" : "16:9宽屏自适应"
            onStatus?("💡 AI 语义意群拆句 (\(modeName)): 共 \(longIndices.count) 句超长句（>\(splitThreshold) 字符）启动并发拆句（复用阶段一译文，仅插「 ｜ 」不重译）...")
            var splitPlans: [BatchPlan] = []
            var splitZhMap: [Int: String] = [:]
            var sp = 0
            var spIndex = 0
            while sp < longIndices.count {
                spIndex += 1
                let spEnd = min(sp + defaultBatchSize, longIndices.count)
                let spIndices = Array(longIndices[sp..<spEnd])
                let spItems = spIndices.map { (id: $0, text: sentences[$0].text) }
                splitPlans.append(BatchPlan(index: spIndex, startCursor: sp, items: spItems))
                for idx in spIndices {
                    if let zh = state.allTranslationsMap[idx]?.zh, !zh.isEmpty {
                        splitZhMap[idx] = zh
                    }
                }
                sp = spEnd
            }
            try await runConcurrentBatches(
                plans: splitPlans,
                splitOnly: true,
                isPortrait: isPortrait,
                title: title,
                sentences: sentences,
                toTranslateIndices: longIndices,
                state: state,
                settings: settings,
                splitZhMap: splitZhMap,
                onStatus: onStatus,
                onProgress: nil,
                pauseCheck: pauseCheck,
                cancellation: cancellation
            )
            resultSentences = state.resultSentences
            let aiSplitCount = state.allTranslationsMap.values.filter { $0.splitEn != nil }.count - splitsBefore
            if aiSplitCount > 0 {
                onStatus?("💡 AI 语义意群拆句 (\(modeName)): 成功对 \(aiSplitCount) 处长句完成中英双向自然对齐切分（音画字幕严整对齐）")
            }
        }

        // 组装最终句子（含拆句后的子片段；未拆句的保持完整）
        var finalSentences: [Sentence] = []
        for (idx, sent) in resultSentences.enumerated() {
            if let item = state.allTranslationsMap[idx],
               let splitEn = item.splitEn, let splitZh = item.splitZh,
               let subSentences = alignAndSplitSentence(originalText: sent.text, splitEn: splitEn, splitZh: splitZh, pauseAfter: sent.pauseAfter) {
                finalSentences.append(contentsOf: subSentences)
            } else {
                var copy = sent
                if let item = state.allTranslationsMap[idx] {
                    copy.translation = item.zh.replacingOccurrences(of: "｜", with: "").replacingOccurrences(of: "|", with: "")
                }
                finalSentences.append(copy)
            }
        }

        // 最终对齐后结果落盘（先存原句+意群切分保障下次秒级恢复，再增量合并子片段）与导出双语对照文本
        var allSplits: [String: (en: String, zh: String)] = [:]
        for (idx, item) in state.allTranslationsMap {
            if let en = item.splitEn, let zh = item.splitZh {
                allSplits[state.resultSentences[idx].text] = (en, zh)
            }
        }
        saveCheckpoint(
            sentences: resultSentences,
            splits: allSplits,
            bookFileURL: bookFileURL,
            bookTitle: title
        )
        saveCheckpoint(
            sentences: finalSentences,
            bookFileURL: bookFileURL,
            bookTitle: title
        )
        if let fileURL = bookFileURL {
            let bilingualTxtURL = fileURL.deletingPathExtension().appendingPathExtension("bilingual.txt")
            exportBilingualWithFallback(sentences: finalSentences, to: bilingualTxtURL, onStatus: onStatus)
        }

        // 汇报整体 Token 消耗与 Context Caching 命中率
        if state.usage.totalTokens > 0 {
            let hitTokens = state.usage.cacheHitTokens
            let missTokens = state.usage.cacheMissTokens
            let totalPrompt = (hitTokens + missTokens > 0) ? (hitTokens + missTokens) : state.usage.promptTokens
            let hitRatio = totalPrompt > 0 ? (Double(hitTokens) / Double(totalPrompt) * 100.0) : 0.0
            let overallElapsed = Date().timeIntervalSince(overallStartTime)
            let overallSpeed = Double(state.usage.completionTokens) / max(overallElapsed, 0.01)

            var tokenDetail = "输入 \(totalPrompt) (缓存命中 \(hitTokens) · \(String(format: "%.1f", hitRatio))% 命中率 · 享 1 折优惠) + 输出 \(state.usage.completionTokens)"
            if state.usage.reasoningTokens > 0 {
                tokenDetail += " (其中思维链深度思考消耗 \(state.usage.reasoningTokens) tokens)"
            }

            if settings.provider == .deepseek {
                // DeepSeek 官方定价: 命中 0.1元/1M, 未命中 1.0元/1M, 输出 2.0元/1M
                let cost = (Double(hitTokens) * 0.1 + Double(missTokens) * 1.0 + Double(state.usage.completionTokens) * 2.0) / 1_000_000.0
                let costStr = cost < 0.01 ? String(format: "%.4f", cost) : String(format: "%.2f", cost)
                onStatus?("💡 DeepSeek Token 统计: \(tokenDetail) · 预估费用约 ¥\(costStr) · 全局生成速率 \(String(format: "%.0f", overallSpeed)) tok/s")
                if state.usage.reasoningTokens > 0 && !settings.disableThinking {
                    onStatus?("💡 提示：当前检测到模型产生了深度思考推理 Token（Reasoning Tokens）。纯翻译任务无需思考，建议在设置中开启「关闭大模型思考模式」以大幅提速。")
                }
            } else {
                onStatus?("💡 翻译 Token 统计: \(tokenDetail) · 总计 \(state.usage.totalTokens) tokens · 全局生成速率 \(String(format: "%.0f", overallSpeed)) tok/s")
            }
        }

        return finalSentences
    }

    /// 并发执行一批翻译/拆句计划（有界并发池：动态补充任务，父侧串行合并与落盘，子任务按需读取已完成译文作上下文）
    private static func runConcurrentBatches(
        plans: [BatchPlan],
        splitOnly: Bool,
        isPortrait: Bool,
        title: String,
        sentences: [Sentence],
        toTranslateIndices: [Int],
        state: BookTranslationState,
        settings: TranslationSettings,
        splitZhMap: [Int: String] = [:],
        onStatus: (@Sendable (String) -> Void)? = nil,
        onProgress: (@Sendable (Int, Int) -> Void)? = nil,
        pauseCheck: (@Sendable () async throws -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws {
        guard !plans.isEmpty else { return }
        let concurrency = max(1, min(settings.concurrentRequests, plans.count))
        let totalToTranslate = toTranslateIndices.count
        let totalPlans = plans.count

        try await withThrowingTaskGroup(of: BatchOutcome.self) { group in
            var next = 0
            var done = 0

            func addNextBatch() {
                guard next < plans.count else { return }
                let plan = plans[next]
                next += 1
                let planNo = plan.index
                let planStartCursor = plan.startCursor

                group.addTask {
                    if cancellation?() == true { throw BookStreamError.cancelled }
                    try await pauseCheck?()

                    // 前情上下文：优先使用已完成批次的译文（并发友好）；未完成时回退英文原文，保证人名/地名对模型始终可见
                    var contextHistory: [(en: String, zh: String)] = []
                    if !splitOnly, planStartCursor > 0 {
                        let startHistory = max(0, planStartCursor - 3)
                        contextHistory = state.lock.withLock {
                            var list: [(en: String, zh: String)] = []
                            let upper = min(planStartCursor, toTranslateIndices.count)
                            for prevIdx in toTranslateIndices[startHistory..<upper] {
                                list.append((en: sentences[prevIdx].text, zh: state.allTranslationsMap[prevIdx]?.zh ?? ""))
                            }
                            return list
                        }
                    }

                    let tagPrefix = splitOnly ? "拆句" : "批次"
                    let tag = "\(tagPrefix) [\(planNo)/\(totalPlans)]"
                    let batchChars = plan.items.reduce(0) { $0 + $1.text.count }
                    let activeModel = settings.model.isEmpty ? settings.provider.defaultModel : settings.model
                    onStatus?("▶︎ 发起\(splitOnly ? " AI 意群拆句" : " API 翻译")请求 \(tag): \(plan.items.count) 句 / \(batchChars) 字符 (索引 #\(plan.items.first?.id ?? 0)#\(plan.items.last?.id ?? 0)) · 模型=\(activeModel)...")
                    let batchStart = Date()

                    let (translations, usage, fallback) = try await translateBatch(
                        items: plan.items,
                        bookTitle: title,
                        contextHistory: contextHistory,
                        isPortrait: isPortrait,
                        batchLabel: tag,
                        splitOnly: splitOnly,
                        splitZhMap: splitZhMap,
                        settings: settings,
                        onStatus: onStatus,
                        cancellation: cancellation
                    )

                    let batchElapsed = Date().timeIntervalSince(batchStart)
                    if let u = usage {
                        let speed = Double(u.completionTokens) / max(batchElapsed, 0.01)
                        var usageDetail = "输入 \(u.promptTokens) (命中 \(u.cacheHitTokens)) + 输出 \(u.completionTokens)"
                        if u.reasoningTokens > 0 {
                            usageDetail += " (含思考 \(u.reasoningTokens))"
                        }
                        onStatus?("✔︎ \(tag) 成功完成 (耗时 \(String(format: "%.1f", batchElapsed))s · \(String(format: "%.0f", speed)) tok/s) · Token: \(usageDetail)")
                    } else {
                        onStatus?("✔︎ \(tag) 成功完成 (耗时 \(String(format: "%.1f", batchElapsed))s)")
                    }
                    return BatchOutcome(translations: translations, usage: usage ?? TranslationUsage(), fallbackCount: fallback)
                }
            }

            for _ in 0..<concurrency { addNextBatch() }
            while let outcome = try await group.next() {
                done += outcome.translations.count
                state.merge(outcome)
                onProgress?(done, totalToTranslate)
                if next < plans.count { addNextBatch() }
            }
        }
    }

    /// 单批次结构化翻译（带书籍背景、前情上下文滑动窗口、纯翻译/纯拆句双模式、断网重连、自适应二分批次降级、Token与缓存提取与显式兜底）
    private static func translateBatch(
        items: [(id: Int, text: String)],
        bookTitle: String? = nil,
        contextHistory: [(en: String, zh: String)] = [],
        isPortrait: Bool = true,
        batchLabel: String = "",
        splitOnly: Bool = false,
        splitZhMap: [Int: String] = [:],
        isTest: Bool = false,
        allowMissingRetry: Bool = true,
        settings: TranslationSettings,
        onStatus: (@Sendable (String) -> Void)? = nil,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> (translations: [Int: TranslationResultItem], usage: TranslationUsage?, fallbackCount: Int) {
        guard !items.isEmpty else { return ([:], nil, 0) }
        if cancellation?() == true { throw BookStreamError.cancelled }

        if settings.provider == .builtInFree {
            let res = try await translateBatchFree(items: items, cancellation: cancellation)
            let itemMap = res.reduce(into: [Int: TranslationResultItem]()) { $0[$1.key] = TranslationResultItem(id: $1.key, zh: $1.value) }
            return (itemMap, nil, 0)
        }

        let screenInstruction = isPortrait ? """
        3. 【手机竖屏短视频排版（9:16 窄画幅）】：
           - 目标画幅为 9:16 竖屏手机，横向宽度较窄（字幕单行容纳约 30~40 字符）。
           - 若输入的某句英文较长（超过 80 字符或约 12~14 词），且包含多个从句或停顿，请在英文意群停顿处与中文对应处同步插入「 ｜ 」管道符。
           - 目标：切分后的每个子片段控制在 6~12 词（中文约 10~18 字），在竖屏中恰好排版为 1~2 行短字幕，绝不遮挡画面。严禁改动英文原本的单词拼写与标点。
           - 中短句请保持原样，切勿过度切分。
        """ : """
        3. 【电脑/影视宽屏排版（16:9 横屏画幅）】：
           - 目标画幅为 16:9 影视宽屏，横向空间宽阔，可从容容纳 20~28 词单行字幕，需保持行文的宏大连贯与电影质感，严禁将中等句子过度切碎！
           - 仅当英文超长（超过 150 字符或约 24 词以上），且包含较长独立从句时，才在自然从句停顿处与中文对应处同步插入「 ｜ 」管道符。
           - 目标：切分后的每个子片段保持在 12~22 词（中文约 20~35 字）左右，保持宽屏单行电影字幕的质感。严禁改动英文原本的单词拼写与标点。
           - 常见句子（140 字符以下）请严格保持完整连贯，切勿过度切分。
        """

        // 双模式 Prompt：纯翻译（更简单更快，保证信达雅） / 纯拆句（只处理意群切分，不干扰翻译质量）
        let systemPrompt: String
        if splitOnly {
            systemPrompt = """
            你是一位精通中英双语字幕排版与意群断句的专家。
            针对输入的每一句英文（附带其高质量中文译文 zh），判断它是否需要做字幕意群切分（仅当句子较长、含多个独立从句或自然停顿点时）。
            要求：
            1. 若需要切分：在英文的自然意群停顿处插入「 ｜ 」管道符，并在给定中文译文 zh 的对应意群处同步插入「 ｜ 」。
               - 严格要求「一一对应、顺序一致」：第 i 个英文片段的中文翻译必须恰好是第 i 个中文片段，不得错位、不得颠倒顺序。
               - 注意：中英文语序往往不同。若中文译文无法按英文片段的顺序逐段一一对应切分，则该句不要切分，直接输出 {"id": N, "en": "", "zh": ""}。
               - 英文必须与原文单词拼写、标点完全一致（严禁增删改任何单词，仅允许插入「 ｜ 」）。
               - 中文译文 zh 的文字必须保持完全不变（严禁重新翻译、润色或增删任何字词，仅允许插入「 ｜ 」）。
            2. 若无需切分：该句输出 {"id": N, "en": "", "zh": ""}。
            \(screenInstruction)
            3. 必须且仅输出严格合法的 JSON 对象，包含 "sentences" 键，格式例如：
            {"sentences": [{"id": 0, "en": "Part 1, ｜ Part 2.", "zh": "片段一，｜片段二。"}, {"id": 1, "en": "", "zh": ""}]}
            """
        } else {
            systemPrompt = """
            你是一位精通英汉文学翻译的国宝级翻译大师。
            请将输入的连续英文句子数组翻译为典雅、地道、信达雅的中文。
            要求：
            1. 结合前后上下文连贯理解，严格保持专有名词、人名、地名、代词指代及叙事语气的前后一致性（如提供前情上下文，请严格沿用前文的人物译名与行文口吻）。
            2. 严格按待翻译数组中的 id 映射，绝不要漏句、合并句子、改变 id 顺序，也不要输出前情参考中的句子。
            3. 必须且仅输出严格合法的 JSON 对象，包含 "sentences" 键，格式例如：
            {"sentences": [{"id": 0, "zh": "译文..."}, {"id": 1, "zh": "译文..."}]}
            """
        }

        // 拆句模式下向模型附带阶段一译文（只插「 ｜ 」不重译，译文质量 100% 由阶段一保障）
        let inputJsonArray = items.map { item -> [String: Any] in
            var obj: [String: Any] = ["id": item.id, "text": item.text]
            if splitOnly, let zh = splitZhMap[item.id] {
                obj["zh"] = zh
            }
            return obj
        }
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
        userPrompt += "【本次待翻译句子数组（请严格输出对应 id 的 JSON 对象）：】\n\(inputJsonString)"

        var requestBody: [String: Any] = [
            "model": settings.model.isEmpty ? settings.provider.defaultModel : settings.model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.3,
            "max_tokens": 4096
        ]
        if settings.provider == .deepseek {
            requestBody["response_format"] = ["type": "json_object"]
        }
        // 思考模式开关：DeepSeek 官方支持 {"thinking": {"type": "disabled"}}；第三方/本地端点若不支持会返回 400，届时自动移除参数重试
        if settings.disableThinking {
            requestBody["thinking"] = ["type": "disabled"]
        }

        let rawEndpoint = settings.endpointURL.isEmpty ? settings.provider.defaultEndpoint : settings.endpointURL
        let resolvedEndpoint = normalizeEndpoint(rawEndpoint)
        guard let url = URL(string: resolvedEndpoint) else {
            throw BookStreamError.audioRenderFailed("无效的翻译 API 端点: \(rawEndpoint)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120.0
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.setValue("Bearer \(settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        }

        let maxRetries = 3
        var currentAttempt = 0
        var lastError: Error?
        let tagPrefix = batchLabel.isEmpty ? "" : "[\(batchLabel)] "
        var fallbackCount = 0

        while currentAttempt < maxRetries {
            if cancellation?() == true { throw BookStreamError.cancelled }
            currentAttempt += 1

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)
                let (data, response) = try await sendRequest(request: request, cancellation: cancellation)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 401 || http.statusCode == 402 || http.statusCode == 403 {
                        let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        throw BookStreamError.audioRenderFailed("翻译 API 认证/账户错误 (\(http.statusCode)): \(errStr.prefix(160))")
                    } else if http.statusCode == 400, requestBody["thinking"] != nil {
                        // 部分端点不支持 thinking 参数：自动移除并以同一次重试预算重发
                        requestBody.removeValue(forKey: "thinking")
                        currentAttempt -= 1
                        onStatus?("  ⚠︎ \(tagPrefix)服务端不支持 thinking 参数 (400)，已自动移除并重试...")
                        continue
                    } else if http.statusCode == 429 || (http.statusCode >= 500 && http.statusCode <= 504) {
                        let delay = Double(currentAttempt) * 2.0
                        onStatus?("  ⚠︎ \(tagPrefix)翻译 API 繁忙/限流 (\(http.statusCode))，等待 \(String(format: "%.1f", delay))s 后自动重试 [\(currentAttempt)/\(maxRetries)]...")
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        continue
                    } else if http.statusCode >= 400 {
                        let errStr = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
                        throw BookStreamError.audioRenderFailed("翻译 API 错误 (\(http.statusCode)): \(errStr.prefix(160))")
                    }
                }

                // 解析返回 JSON 与 Token Usage
                var resultMap: [Int: TranslationResultItem] = [:]
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
                        let details = usage["completion_tokens_details"] as? [String: Any]
                        let rTokens = (details?["reasoning_tokens"] as? Int) ?? ((usage["reasoning_tokens"] as? Int) ?? 0)
                        let hitTokens = (usage["prompt_cache_hit_tokens"] as? Int) ?? 0
                        let missTokens = (usage["prompt_cache_miss_tokens"] as? Int) ?? 0
                        var u = TranslationUsage()
                        u.add(prompt: pTokens, completion: cTokens, reasoning: rTokens, hit: hitTokens, miss: missTokens)
                        usageStats = u
                    }
                }

                // 纯拆句模式：只保留「守门员双重严格校验通过」的拆句条目。
                // ① 英文回显必须与原文单词完全一致（防篡改熔断）；② 去管道符后的译文必须与阶段一译文完全一致（防重译/润色）。
                // 无需切分（en/zh 为空）或任一校验失败的条目一律丢弃 → 原句保持不拆，译文 100% 保持阶段一质量。
                if splitOnly {
                    func stripped(_ s: String) -> String {
                        s.replacingOccurrences(of: "｜", with: "")
                         .replacingOccurrences(of: "|", with: "")
                         .filter { !$0.isWhitespace }
                    }
                    var validSplits: [Int: TranslationResultItem] = [:]
                    for item in items {
                        guard let it = resultMap[item.id], let en = it.splitEn, let zh = it.splitZh else { continue }
                        guard alignAndSplitSentence(originalText: item.text, splitEn: en, splitZh: zh, pauseAfter: 0) != nil else { continue }
                        if let srcZh = splitZhMap[item.id] {
                            guard stripped(zh) == stripped(srcZh) else { continue }
                        }
                        validSplits[item.id] = it
                    }
                    resultMap = validSplits
                }

                // 缺句校验：拆句模式缺句 = 不拆（安全跳过）；翻译模式缺句 → LLM 单句补译重试，绝不静默降级机翻
                let missing: [(id: Int, text: String)]
                if splitOnly {
                    missing = items.filter { resultMap[$0.id] == nil }
                } else {
                    missing = items.filter { resultMap[$0.id] == nil || resultMap[$0.id]?.zh.isEmpty == true }
                }

                if !missing.isEmpty && !isTest && !splitOnly {
                    if allowMissingRetry {
                        onStatus?("  ⚠︎ \(tagPrefix)模型返回缺 \(missing.count) 句（疑似格式偏差），正在单句补译重试（不降级机翻）...")
                        let (retryMap, retryUsage, retryFallback) = try await translateBatch(
                            items: missing,
                            bookTitle: bookTitle,
                            contextHistory: contextHistory,
                            isPortrait: isPortrait,
                            batchLabel: "\(batchLabel)-补",
                            splitOnly: false,
                            splitZhMap: splitZhMap,
                            isTest: isTest,
                            allowMissingRetry: false,
                            settings: settings,
                            onStatus: onStatus,
                            cancellation: cancellation
                        )
                        for (k, v) in retryMap { resultMap[k] = v }
                        if let ru = retryUsage {
                            if usageStats == nil { usageStats = TranslationUsage() }
                            usageStats?.add(prompt: ru.promptTokens, completion: ru.completionTokens, reasoning: ru.reasoningTokens, hit: ru.cacheHitTokens, miss: ru.cacheMissTokens)
                        }
                        fallbackCount += retryFallback
                        let stillMissing = missing.filter { resultMap[$0.id] == nil || resultMap[$0.id]?.zh.isEmpty == true }
                        for item in stillMissing {
                            onStatus?("  ⚠︎ \(tagPrefix)单句补译仍失败，启用备用机翻通道兜底（可能影响术语一致性，导出后建议人工复核）: 「\(item.text.prefix(60))...」")
                            let fb = await translateSingleFree(text: item.text)
                            resultMap[item.id] = TranslationResultItem(id: item.id, zh: fb)
                            fallbackCount += 1
                        }
                    } else {
                        for item in missing {
                            onStatus?("  ⚠︎ \(tagPrefix)单句补译失败，启用备用机翻通道兜底（可能影响术语一致性）: 「\(item.text.prefix(60))...」")
                            let fb = await translateSingleFree(text: item.text)
                            resultMap[item.id] = TranslationResultItem(id: item.id, zh: fb)
                            fallbackCount += 1
                        }
                    }
                }

                return (resultMap, usageStats, fallbackCount)
            } catch {
                if cancellation?() == true || Task.isCancelled || (error as? BookStreamError) == .cancelled || error is CancellationError {
                    throw BookStreamError.cancelled
                }
                if let bsErr = error as? BookStreamError, case .audioRenderFailed(let msg) = bsErr, msg.contains("认证/账户错误") {
                    throw bsErr
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
                    let delay = Double(currentAttempt) * 2.0
                    let reason = isNetworkDown ? "网络连接超时 / 中断" : "请求异常 (\(error.localizedDescription))"
                    onStatus?("  ⚠︎ \(tagPrefix)\(reason)，正在等待重连，\(String(format: "%.1f", delay))s 后自动重试 [\(currentAttempt)/\(maxRetries)]...")
                    do {
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    } catch {
                        throw BookStreamError.cancelled
                    }
                } else {
                    break
                }
            }
        }

        // 非测试模式下：若多句批次在重试耗尽后依然失败，启动「自适应二分批次降级（Adaptive Binary Splitting）」
        // 将耗时过长或超时的大批次自动拆为 2 个小批次，大幅减小单次 Token 输出量与推理时长
        if !isTest && items.count > 1 {
            let mid = items.count / 2
            let firstHalf = Array(items[0..<mid])
            let secondHalf = Array(items[mid..<items.count])
            onStatus?("  💡 \(tagPrefix)响应耗时过长或网络超时，已自动启动自适应二分拆分降级（\(items.count) 句 → \(firstHalf.count) 句 + \(secondHalf.count) 句），加速推进...")

            let (res1, usage1, fb1) = try await translateBatch(
                items: firstHalf,
                bookTitle: bookTitle,
                contextHistory: contextHistory,
                isPortrait: isPortrait,
                batchLabel: "\(batchLabel)-A",
                splitOnly: splitOnly,
                splitZhMap: splitZhMap,
                settings: settings,
                onStatus: onStatus,
                cancellation: cancellation
            )

            var updatedHistory = contextHistory
            for item in firstHalf {
                if let zh = res1[item.id]?.zh, !zh.isEmpty {
                    updatedHistory.append((en: item.text, zh: zh))
                }
            }
            if updatedHistory.count > 3 {
                updatedHistory = Array(updatedHistory.suffix(3))
            }

            let (res2, usage2, fb2) = try await translateBatch(
                items: secondHalf,
                bookTitle: bookTitle,
                contextHistory: updatedHistory,
                isPortrait: isPortrait,
                batchLabel: "\(batchLabel)-B",
                splitOnly: splitOnly,
                splitZhMap: splitZhMap,
                settings: settings,
                onStatus: onStatus,
                cancellation: cancellation
            )

            var combinedRes = res1
            for (k, v) in res2 { combinedRes[k] = v }

            var combinedUsage = TranslationUsage()
            if let u1 = usage1 { combinedUsage.add(prompt: u1.promptTokens, completion: u1.completionTokens, reasoning: u1.reasoningTokens, hit: u1.cacheHitTokens, miss: u1.cacheMissTokens) }
            if let u2 = usage2 { combinedUsage.add(prompt: u2.promptTokens, completion: u2.completionTokens, reasoning: u2.reasoningTokens, hit: u2.cacheHitTokens, miss: u2.cacheMissTokens) }

            return (combinedRes, combinedUsage.totalTokens > 0 ? combinedUsage : nil, fb1 + fb2)
        }

        // 非测试模式下：单句在 120s 及多次重试后依然超时，启用备用轻量免配置通道兜底，绝不让整本数十小时导出崩溃中断
        if !isTest && items.count == 1 {
            let single = items[0]
            let errReason = lastError?.localizedDescription ?? "请求超时"
            onStatus?("  ⚠︎ \(tagPrefix)单句 API 响应受阻 (\(errReason))，已启用备用通道快速兜底并保持导出（该句译文可能不够典雅，建议导出后人工复核）...")
            let fallback = await translateSingleFree(text: single.text)
            let item = TranslationResultItem(id: single.id, zh: fallback)
            return ([single.id: item], nil, 1)
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
    private static func parseTranslationJSON(_ content: String) -> [Int: TranslationResultItem] {
        var map: [Int: TranslationResultItem] = [:]
        let cleaned = content
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8) else { return map }

        func processObj(_ obj: [String: Any]) {
            guard let id = obj["id"] as? Int,
                  let zh = (obj["zh"] as? String) ?? (obj["translation"] as? String) else { return }
            let cleanZh = zh.trimmingCharacters(in: .whitespacesAndNewlines)
            let en = (obj["en"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let en = en, (en.contains("｜") || en.contains("|")) && (cleanZh.contains("｜") || cleanZh.contains("|")) {
                map[id] = TranslationResultItem(id: id, zh: cleanZh, splitEn: en, splitZh: cleanZh)
            } else {
                map[id] = TranslationResultItem(id: id, zh: cleanZh, splitEn: nil, splitZh: nil)
            }
        }

        if let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for obj in list { processObj(obj) }
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // 兼容可能包在外层对象如 {"sentences": [...]} 或 {"translations": [...]}
            for (_, val) in dict {
                if let list = val as? [[String: Any]] {
                    for obj in list { processObj(obj) }
                }
            }
        }
        return map
    }

    private static let translationSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120.0
        config.timeoutIntervalForResource = 300.0
        return URLSession(configuration: config)
    }()

    /// 发送可取消且线程安全的网络请求（支持 Task 取消与外部高频看门狗即时中断）
    private static func sendRequest(
        request: URLRequest,
        cancellation: (@Sendable () -> Bool)? = nil
    ) async throws -> (Data, URLResponse) {
        if cancellation?() == true || Task.isCancelled {
            throw BookStreamError.cancelled
        }

        final class RequestState: @unchecked Sendable {
            private let lock = NSLock()
            private var isResumed = false
            var task: URLSessionDataTask?
            var continuation: CheckedContinuation<(Data, URLResponse), Error>?
            var watcher: Task<Void, Never>?

            func resumeOnce(returning: (Data, URLResponse)?, throwing: Error?) {
                lock.lock()
                defer { lock.unlock() }
                guard !isResumed else { return }
                isResumed = true
                watcher?.cancel()
                if let error = throwing {
                    continuation?.resume(throwing: error)
                } else if let ret = returning {
                    continuation?.resume(returning: ret)
                }
            }

            func cancel(with error: Error = BookStreamError.cancelled) {
                lock.lock()
                defer { lock.unlock() }
                guard !isResumed else { return }
                isResumed = true
                task?.cancel()
                watcher?.cancel()
                continuation?.resume(throwing: error)
            }
        }

        let state = RequestState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.continuation = continuation

                if cancellation?() == true || Task.isCancelled {
                    state.cancel(with: BookStreamError.cancelled)
                    return
                }

                let task = translationSession.dataTask(with: request) { data, response, error in
                    if let error = error {
                        let nsErr = error as NSError
                        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
                            state.resumeOnce(returning: nil, throwing: BookStreamError.cancelled)
                        } else {
                            state.resumeOnce(returning: nil, throwing: error)
                        }
                    } else if let data = data, let response = response {
                        state.resumeOnce(returning: (data, response), throwing: nil)
                    } else {
                        state.resumeOnce(returning: nil, throwing: BookStreamError.audioRenderFailed("未知网络错误"))
                    }
                }
                state.task = task
                task.resume()

                // 启动 50ms 极速看门狗，监听外部 cancelFlag，实现真正的即时毫秒级取消
                if let cancellation = cancellation {
                    state.watcher = Task {
                        while !Task.isCancelled {
                            if cancellation() {
                                state.cancel(with: BookStreamError.cancelled)
                                break
                            }
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                    }
                }
            }
        } onCancel: {
            state.cancel(with: BookStreamError.cancelled)
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

    /// 测试连接与翻译质量（严格测试目标接口，不使用降级与兜底）
    public static func testConnection(settings: TranslationSettings) async throws -> String {
        let testSentence = (id: 0, text: "It is a truth universally acknowledged, that a single man in possession of a good fortune, must be in want of a wife.")
        let (res, _, _) = try await translateBatch(items: [testSentence], batchLabel: "测试连接", isTest: true, settings: settings)
        guard let zh = res[0]?.zh, !zh.isEmpty else {
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

    /// 尝试在已有存档字典中通过子片段贪婪拼接还原未切分的长句（向前兼容被旧版本切碎的存档）
    private static func matchSubpieces(
        text: String,
        translations: [String: String]
    ) -> (zh: String, splitEn: String, splitZh: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var remainder = trimmed
        var matchedEnPieces: [String] = []
        var matchedZhPieces: [String] = []

        while !remainder.isEmpty {
            var found = false
            let candidates = translations.keys.filter {
                remainder.lowercased().hasPrefix($0.lowercased())
            }.sorted { $0.count > $1.count }

            for key in candidates {
                if let zh = translations[key] {
                    matchedEnPieces.append(key)
                    matchedZhPieces.append(zh)
                    remainder = remainder.dropFirst(key.count).trimmingCharacters(in: .whitespacesAndNewlines)
                    found = true
                    break
                }
            }

            if !found {
                return nil
            }
        }

        guard matchedEnPieces.count > 1 else { return nil }
        let splitZh = matchedZhPieces.joined(separator: "｜")
        let splitEn = matchedEnPieces.joined(separator: " ｜ ")
        let cleanZh = matchedZhPieces.joined(separator: "")
        return (cleanZh, splitEn, splitZh)
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
                } else if let sub = matchSubpieces(text: key, translations: translations) {
                    result[i].translation = sub.zh
                    count += 1
                }
            } else {
                count += 1
            }
        }

        return (result, count, cpURL)
    }

    /// 从本地存档恢复已有的 AI 意群切分（秒级复用，节省 100% 重复 Token）
    public static func restoreSplitsFromCheckpoint(
        sentences: [Sentence] = [],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil
    ) -> [String: (en: String, zh: String)] {
        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"
        let cpURL = getCheckpointURL(bookFileURL: bookFileURL, bookTitle: title)

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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }

        var splitsMap: [String: (en: String, zh: String)] = [:]
        if let jsonSplits = json["splits"] as? [String: [String: String]] {
            for (k, v) in jsonSplits {
                if let en = v["en"], let zh = v["zh"] {
                    splitsMap[k] = (en, zh)
                }
            }
        }

        // 向前兼容：若 splitsMap 中未显式包含某原句，但可从 translations 中的子片段拼接得出，自动恢复切分
        if let translations = json["translations"] as? [String: String] {
            for s in sentences {
                let key = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if splitsMap[key] == nil {
                    if let sub = matchSubpieces(text: key, translations: translations) {
                        splitsMap[key] = (sub.splitEn, sub.splitZh)
                    }
                }
            }
        }

        return splitsMap
    }

    /// 增量实时保存翻译存档（每批次自动落盘，支持增量合并与 AI 意群切分留存，绝不丢失任何原句）
    public static func saveCheckpoint(
        sentences: [Sentence],
        splits: [String: (en: String, zh: String)] = [:],
        bookFileURL: URL? = nil,
        bookTitle: String? = nil
    ) {
        let title = bookTitle ?? bookFileURL?.deletingPathExtension().lastPathComponent ?? "book"
        let cpURL = getCheckpointURL(bookFileURL: bookFileURL, bookTitle: title)

        var map: [String: String] = [:]
        var existingSplits: [String: [String: String]] = [:]

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

        if let data = loadedData,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let existingTr = json["translations"] as? [String: String] {
                map = existingTr
            }
            if let exSp = json["splits"] as? [String: [String: String]] {
                existingSplits = exSp
            }
        }

        for s in sentences {
            if let zh = s.translation?.trimmingCharacters(in: .whitespacesAndNewlines), !zh.isEmpty {
                let key = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
                map[key] = zh
            }
        }

        for (orig, pair) in splits {
            let key = orig.trimmingCharacters(in: .whitespacesAndNewlines)
            existingSplits[key] = ["en": pair.en, "zh": pair.zh]
        }

        guard !map.isEmpty else { return }

        var payload: [String: Any] = [
            "bookTitle": title,
            "version": "1.0",
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "totalSentences": max(sentences.count, map.count),
            "completedSentences": map.count,
            "translations": map
        ]
        if !existingSplits.isEmpty {
            payload["splits"] = existingSplits
        }

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

    /// 导出双语对照文本：优先书旁，失败时回退 ~/.bookstream/bilingual/，任何情况都在日志中明示结果
    private static func exportBilingualWithFallback(
        sentences: [Sentence],
        to primaryURL: URL,
        onStatus: (@Sendable (String) -> Void)? = nil
    ) {
        do {
            try exportBilingualText(sentences: sentences, to: primaryURL)
            onStatus?("💾 已导出双语对照文本: \(primaryURL.lastPathComponent)")
        } catch {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let fallbackDir = home.appendingPathComponent(".bookstream/bilingual")
            try? FileManager.default.createDirectory(at: fallbackDir, withIntermediateDirectories: true)
            let fallbackURL = fallbackDir.appendingPathComponent(primaryURL.lastPathComponent)
            do {
                try exportBilingualText(sentences: sentences, to: fallbackURL)
                onStatus?("  ⚠︎ 书旁双语文本写入失败（\(error.localizedDescription)），已回退保存至 \(fallbackURL.path)")
            } catch {
                onStatus?("  ⚠︎ 双语对照文本导出失败: \(error.localizedDescription)")
            }
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
