import Foundation

// MARK: - 数据模型

/// 全球下一代 AI 语音引擎类型
public enum TTSEngineType: String, CaseIterable, Codable, Identifiable, Sendable {
    case kokoro      = "kokoro"      // Kokoro-82M 本地顶级神经网络 (af_heart/am_adam，超拟真·离线无限制)
    case edgeTTS     = "edgeTTS"     // 微软广播级 Neural (云希/Christopher/晓晓，48kHz 高保真，免 Key)
    case customAPI   = "customAPI"   // 自定义 API (OpenAI tts-1-hd / ElevenLabs / CosyVoice / 本地私有服务)

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .kokoro: return "Kokoro-82M 本地神经模型 (顶级真人·离线无限量)"
        case .edgeTTS: return "微软广播级 Neural (极高拟真·免Key)"
        case .customAPI: return "自定义 API (OpenAI / ElevenLabs / CosyVoice)"
        }
    }
}

/// 书籍分句后的一个句子。
public struct Sentence: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    /// 中文译文（用于双语字幕展示，可选）。
    public var translation: String?
    /// 本句之后的停顿（秒）：段落末尾（空行）更长，句末为短停顿，营造真人朗读节奏。
    public var pauseAfter: Double

    public init(id: Int, text: String, translation: String? = nil, pauseAfter: Double = 0) {
        self.id = id
        self.text = text
        self.translation = translation
        self.pauseAfter = pauseAfter
    }
}

/// 字幕条目（毫秒级时间轴）。
public struct SubtitleEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let text: String
    /// 中文译文（用于双语字幕展示，可选）。
    public var translation: String?

    public init(id: Int, start: Double, end: Double, text: String, translation: String? = nil) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.translation = translation
    }
}

/// 全局音频常量（44.1 kHz 为标准 PCM 目标采样率）。
public enum AudioFormat {
    public static let sampleRate: Double = 44100.0
    public static let sampleRateInt: Int32 = 44100
}

/// 已确定时间轴的片段：以 44.1 kHz 采样帧为单位（PTS 精度即采样帧精度）。
public struct TimedSegment: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
    /// 中文译文（用于双语字幕展示，可选）。
    public let translation: String?
    public let startFrame: Int64
    public let endFrame: Int64
    /// 语音实际发音结束的帧位置（不包含句尾追加的静音停顿）。若未显式指定，自动按真实比例推导。
    public let speechEndFrame: Int64?

    public var start: Double { Double(startFrame) / AudioFormat.sampleRate }
    public var end: Double { Double(endFrame) / AudioFormat.sampleRate }
    public var duration: Double { end - start }

    /// 语音实际发音持续时间（卡拉OK点亮基准，精准杜绝句尾停顿导致的文字滞后）。
    public var speechDuration: Double {
        if let se = speechEndFrame {
            return max(0.05, Double(se - startFrame) / AudioFormat.sampleRate)
        }
        return max(0.05, duration * 0.84)
    }

    public init(id: Int, text: String, translation: String? = nil, startFrame: Int64, endFrame: Int64, speechEndFrame: Int64? = nil) {
        self.id = id
        self.text = text
        self.translation = translation
        self.startFrame = startFrame
        self.endFrame = endFrame
        self.speechEndFrame = speechEndFrame
    }
}

/// 章节标记：从文本或时间轴中识别出的小节/章节起点。
public struct ChapterMarker: Identifiable, Sendable, Equatable {
    public let id: Int
    public let title: String
    public let startFrame: Int64
    public let endFrame: Int64

    public var start: Double { Double(startFrame) / AudioFormat.sampleRate }
    public var end: Double { Double(endFrame) / AudioFormat.sampleRate }
    public var duration: Double { end - start }

    public init(id: Int, title: String, startFrame: Int64, endFrame: Int64) {
        self.id = id
        self.title = title
        self.startFrame = startFrame
        self.endFrame = endFrame
    }
}

/// 输入文档类型。
public enum InputKind: Sendable {
    case book(title: String, sentences: [Sentence])
    case subtitles(title: String, entries: [SubtitleEntry])
}

// MARK: - 错误类型

public enum BookStreamError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case unzipFailed(String)
    case epubExtractionFailed(String)
    case audioRenderFailed(String)
    case videoRenderFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile(let ext):
            return "不支持的输入格式: \(ext)"
        case .unzipFailed(let msg):
            return "EPUB 解压失败: \(msg)"
        case .epubExtractionFailed(let msg):
            return "EPUB 文本提取失败: \(msg)"
        case .audioRenderFailed(let msg):
            return "音频渲染失败: \(msg)"
        case .videoRenderFailed(let msg):
            return "视频渲染失败: \(msg)"
        case .cancelled:
            return "任务已取消"
        }
    }
}

// MARK: - 文本处理（分句 / 文件读取）

/// 解析期结构与长句处理记录（仅影响解析分段，不修改原文）。
public enum TextFixKind: String, Sendable, Equatable {
    case splitLong = "长句拆分"
    case stripBoilerplate = "剥离出版方样板"
    case skipTOC = "跳过目录"
}

public struct TextFix: Sendable, Equatable {
    public let kind: TextFixKind
    public let original: String   // 原文片段
    public let repaired: String   // 修复后片段
    public let paraIndex: Int     // 所在段落（1-based）

    public init(kind: TextFixKind, original: String, repaired: String, paraIndex: Int) {
        self.kind = kind
        self.original = original
        self.repaired = repaired
        self.paraIndex = paraIndex
    }
}

public enum TextProcessor {

    /// 计算文本中汉字比例（0.0 ~ 1.0）
    public static func hanRatio(of text: String) -> Double {
        let hanChars = text.unicodeScalars.filter {
            (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value)
        }.count
        let totalLetters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard totalLetters > 0 else { return 0 }
        return Double(hanChars) / Double(totalLetters)
    }

    /// 判断文本是否主要为英文
    public static func isPrimarilyEnglish(_ text: String) -> Bool {
        let latinCount = text.unicodeScalars.filter { ($0.value >= 0x0041 && $0.value <= 0x005A) || ($0.value >= 0x0061 && $0.value <= 0x007A) }.count
        let hanCount = text.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }.count
        return latinCount > 0 && latinCount >= hanCount * 2
    }

    /// 标点分句：以句号/问号/感叹号为边界；逗号、分号仅作句中停顿。
    /// 合并过短碎片（< 2 字符）至上一句，保证语流连贯。
    public static func splitSentences(_ text: String) -> [String] {
        splitSentencesWithPauses(text).map { $0.text }
    }

    /// 章节识别正则：中英文常见章节/分卷/回目标题模式（如 Chapter 1 / BOOK I / 第一章 / 序言）。
    public static let chapterRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "^(?i:\\s*(?:chapter|book|part|section|act|scene|volume)\\s+(?:[0-9]+|[ivxlcdm]+|[a-z]+)|第\\s*[0-9一二三四五六七八九十百千万]+\\s*[章回节卷部篇]|序[言章]|前言|后记|尾声|引子)\\b.*$",
        options: []
    )

    /// 判断一行文本是否为标题、章节头、作者署名或元数据行（无需补句末标点，且换行后不与正文硬合并）。
    public static func isHeadingOrTitleLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let ns = trimmed as NSString
        let fullRange = NSRange(location: 0, length: ns.length)

        // 1) 命中章节/卷标/序跋正则（BOOK I / Chapter 1 / 第一章 / 序言 等）
        if let reg = chapterRegex, reg.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
            return true
        }

        // 2) 常见独立英文序跋头（Preface / Prologue / Epilogue / Introduction / Dedication / Conclusion）
        let specialHeadings = ["preface", "prologue", "epilogue", "introduction", "dedication", "conclusion", "contents"]
        if specialHeadings.contains(trimmed.lowercased()) {
            return true
        }

        // 3) 署名与元数据行（By Homer / Translated by ... / Author: ... / Title: ...）
        let bylinePatterns = [
            "^(?i:(?:translated|written|edited|compiled|illustrated)\\s+by\\b.*)$",
            "^(?i:by\\s+[A-Z\u{4e00}-\u{9fa5}].*)$",
            "^(?i:(?:author|title|translator|editor|illustrator)\\s*[:：].*)$",
            "^.+\\s+(?i:by)\\s+[A-Z\u{4e00}-\u{9fa5}].*$" // 如 "The Odyssey By Homer"
        ]
        for pat in bylinePatterns {
            if let reg = try? NSRegularExpression(pattern: pat),
               reg.firstMatch(in: trimmed, options: [], range: fullRange) != nil {
                return true
            }
        }

        // 4) 简短全大写英文标题行（如 "THE ODYSSEY" / "PLAYING PILGRIMS"）
        if trimmed.count <= 50,
           trimmed.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isWhitespace || $0.isNumber || "-:—–".contains($0)) }),
           trimmed.contains(where: { $0.isLetter }) {
            return true
        }

        return false
    }

    /// 分句并标注句后停顿（秒）：空行后的段落末尾 1.0s，普通句末 0.4s。
    /// 停顿感明显（配合“停顿感”滑块 0~2 倍），营造真人朗读节奏。
    /// - 先统一换行符（\r\n / \r → \n），保证 Windows 换行文本也能识别空行段落；
    /// - 硬折行合并：行尾无句末标点时不在此断句，换行当作空格继续累积，
    ///   直到真正的句号处成句——避免「换行句」被从行中间腰斩；
    /// - 标题/章节行保护：`BOOK I`、`The Odyssey By Homer` 等独立标题换行即成句，绝不与后续正文合并；
    /// - 数字小数与英文缩写保护：`3.14`、`Mr.`、`e.g.` 中的句点不作为句边界。
    public static func splitSentencesWithPauses(_ text: String) -> [(text: String, pauseAfter: Double)] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let chars = Array(normalized)
        var sentences: [(text: String, pauseAfter: Double)] = []
        var current = ""
        var pendingTerminator = ""
        var lastFlushedIndex: Int? = nil
        var lineHasContent = false
        let boundaries: Set<Character> = [".", "!", "?", "。", "！", "？"]
        // 常见英文缩写（纯缩写词，句点后不拆句：Mr. / e.g. / St. / a.m. / Gen. / Capt. / U.S. …）。
        let abbreviations: Set<String> = [
            "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
            "gen", "col", "capt", "lt", "sgt", "maj", "rev", "hon", "gov", "sen", "rep", "lord", "lady",
            "e.g", "i.e", "etc", "inc", "ltd", "corp", "co", "fig", "eq",
            "vol", "vols", "chap", "ch", "sec", "no", "nos", "p", "pp", "ed", "al", "vs", "v", "ca", "approx", "dept", "univ", "assoc",
            "a.m", "p.m", "u.s", "u.k", "b.c", "a.d", "c.e", "b.c.e", "ave", "rd", "blvd", "ft", "sq", "mt",
            "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "oct", "nov", "dec"
        ]

        func flush() {
            let s = (current + pendingTerminator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                // 章节标题单独给予更长呼吸停顿（1.2s），普通句内停顿 0.4s
                let isHeading = isHeadingOrTitleLine(s)
                let defaultPause = isHeading ? 1.2 : 0.4
                sentences.append((s, defaultPause))
                lastFlushedIndex = sentences.count - 1
            }
            current = ""
            pendingTerminator = ""
        }

        /// 句点是否应视为句边界（数字小数 / 英文缩写 → 不拆）。
        func isProtectedDot(_ idx: Int) -> Bool {
            guard chars[idx] == "." else { return false }
            let prev = idx > 0 ? chars[idx - 1] : nil
            let next = idx + 1 < chars.count ? chars[idx + 1] : nil
            // 小数：3.14 / 3.5公里（前后是数字）
            if let p = prev, let n = next, p.isNumber, n.isNumber { return true }
            // 缩写紧跟字母：Mr.Smith
            if let p = prev, let n = next, p.isLetter, n.isLetter { return true }
            // 缩写表命中：current 末尾的 ASCII 字母串（含内部点，如 "a.m"），
            // 兼容「他说Mr」这种中英紧邻写法
            let trailing = String(current.reversed().prefix { ($0.isASCII && $0.isLetter) || $0 == "." }.reversed())
                .lowercased()
            if abbreviations.contains(trailing) { return true }
            return false
        }

        for (idx, ch) in chars.enumerated() {
            if ch == "\n" {
                if !pendingTerminator.isEmpty {
                    // 行尾是句末标点 → 成句
                    flush()
                } else if !lineHasContent {
                    // 空行（本行无任何内容）→ 段落结束：段末停顿 1.0s（可由 pauseScale 自由倍乘）
                    if !current.isEmpty || !pendingTerminator.isEmpty { flush() }
                    if let li = lastFlushedIndex {
                        sentences[li].pauseAfter = 1.0
                    }
                } else if isHeadingOrTitleLine(current) {
                    // 标题或章节头行尾换行：成独立句子，绝不与后续正文合并
                    flush()
                } else {
                    // 行尾无句末标点 → 硬折行合并（换行视作空格）
                    current += " "
                }
                lineHasContent = false
                continue
            }
            if boundaries.contains(ch) {
                if ch == "." && isProtectedDot(idx) {
                    // 数字 / 缩写中的句点：并入文本，不当作句边界
                    current.append(ch)
                    lineHasContent = true
                } else {
                    // 句末标点（可连续，如 ... 或 !?）
                    pendingTerminator.append(ch)
                }
                continue
            }
            if !pendingTerminator.isEmpty {
                // 引号内的句末标点：处理右引号归属，避免「!」+ 右引号把引号吞掉
                let quoteChars: Set<Character> = ["\"", "'", "”", "’", "»", "」", "』", ")", "]", "}", "）", "】"]
                if quoteChars.contains(ch) {
                    // 引号后紧跟小写引述归属（said/sighed/replied…）→ 句子继续
                    var j = idx + 1
                    while j < chars.count && chars[j].isWhitespace { j += 1 }
                    let isAttribution = j < chars.count
                        && chars[j].isASCII && chars[j].isLetter && chars[j].isLowercase
                    if isAttribution {
                        current.append(pendingTerminator)
                        current.append(ch)
                        pendingTerminator = ""
                        continue
                    }
                    // 否则右引号归本句（"Help!" He ran. → "Help!"）
                    pendingTerminator.append(ch)
                    flush()
                    continue
                }
                // 非标点字符出现 → 上一句结束
                flush()
            }
            if ch == " " && current.isEmpty { continue }
            current.append(ch)
            if !ch.isWhitespace { lineHasContent = true }
        }
        if !current.isEmpty || !pendingTerminator.isEmpty { flush() }

        // 合并过短碎片（< 2 字符）至上一句，保留其停顿标记
        var merged: [(text: String, pauseAfter: Double)] = []
        for s in sentences {
            if s.text.count < 2, var last = merged.last {
                last.text += " " + s.text
                last.pauseAfter = max(last.pauseAfter, s.pauseAfter)
                merged[merged.count - 1] = last
            } else {
                merged.append(s)
            }
        }
        // 文本末尾的最后一句必然属于最后一个段落：补上段末停顿
        if var last = merged.last {
            last.pauseAfter = 1.0
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// 解析书籍文件；完全保留电子书自身完整的标点与文本，绝不篡改标点；
    /// `splitLong` 开启时按语法从句与自然停顿拆分超长句（画幅自适应：9:16竖屏 ~36字/80字符，16:9横屏 ~60字/140字符）。
    public static func parseBookFile(
        url: URL,
        splitLong: Bool = true,
        isPortrait: Bool = false
    ) throws -> (sentences: [Sentence], fixes: [TextFix]) {
        let ext = url.pathExtension.lowercased()
        let rawText: String
        switch ext {
        case "txt":
            rawText = try readText(url)
        case "epub":
            rawText = try EpubExtractor.extractText(from: url)
        default:
            throw BookStreamError.unsupportedFile(ext)
        }
        let (body1, stripped) = stripGutenbergBoilerplate(rawText)
        let (body2, webFixes) = stripWebNovelNoise(body1)
        let (body3, headingStripped) = stripTOC(body2)
        var fixes = stripped + webFixes + headingStripped

        let parts = splitSentencesWithPauses(body3)
        if splitLong {
            let maxZh = isPortrait ? 36 : 60
            let maxEn = isPortrait ? 80 : 140
            let (splitParts, splitFixes) = splitLongSentences(parts, maxChars: maxZh, maxEnglishChars: maxEn)
            fixes.append(contentsOf: splitFixes)
            guard !splitParts.isEmpty else { throw BookStreamError.unsupportedFile("空文本") }
            let splitSentences = splitParts.enumerated().map {
                Sentence(id: $0.offset, text: $0.element.text, pauseAfter: $0.element.pauseAfter)
            }
            return (splitSentences, fixes)
        }
        guard !parts.isEmpty else { throw BookStreamError.unsupportedFile("空文本") }
        let sentences = parts.enumerated().map {
            Sentence(id: $0.offset, text: $0.element.text, pauseAfter: $0.element.pauseAfter)
        }
        return (sentences, fixes)
    }

    /// 剥离 Project Gutenberg 头尾样板（License 声明等）与纯装饰分隔行（---- / *** 等）。
    /// 识别 `*** START OF THE PROJECT GUTENBERG EBOOK ... ***` 与对应的 END 标记；
    /// 只保留 START 与 END 之间的正文（含原书封面/目录/章节）。
    public static func stripGutenbergBoilerplate(_ text: String) -> (text: String, fixes: [TextFix]) {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var fixes: [TextFix] = []
        var startIdx: Int?
        var endIdx: Int?
        for (i, line) in lines.enumerated() {
            let upper = line.uppercased()
            if startIdx == nil, upper.contains("START OF THE PROJECT GUTENBERG") { startIdx = i }
            if endIdx == nil, upper.contains("END OF THE PROJECT GUTENBERG") { endIdx = i }
        }
        var kept = lines
        if let s = startIdx, let e = endIdx, s < e {
            // 双标记齐全：保留 (s+1)..<e
            fixes.append(TextFix(kind: .stripBoilerplate,
                                 original: "\(lines[s].prefix(40))…（头部样板）",
                                 repaired: "（已剥离）", paraIndex: 0))
            fixes.append(TextFix(kind: .stripBoilerplate,
                                 original: "\(lines[e].prefix(40))…（尾部样板）",
                                 repaired: "（已剥离）", paraIndex: 0))
            kept = Array(lines[(s + 1)..<e])
        } else if let s = startIdx {
            fixes.append(TextFix(kind: .stripBoilerplate,
                                 original: "\(lines[s].prefix(40))…（头部样板）",
                                 repaired: "（已剥离）", paraIndex: 0))
            kept = Array(lines[(s + 1)...])
        } else if let e = endIdx {
            fixes.append(TextFix(kind: .stripBoilerplate,
                                 original: "\(lines[e].prefix(40))…（尾部样板）",
                                 repaired: "（已剥离）", paraIndex: 0))
            kept = Array(lines[..<e])
        }
        // 纯装饰分隔行（全由 - = * _ ~ 组成）剔除
        let decorative = kept.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { "-=*_~".contains($0) }
        }
        if !decorative.isEmpty {
            fixes.append(TextFix(kind: .stripBoilerplate,
                                 original: "\(decorative.count) 行装饰分隔线",
                                 repaired: "（已剥离）", paraIndex: 0))
            kept = kept.filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || !trimmed.allSatisfy { "-=*_~".contains($0) }
            }
        }
        return (kept.joined(separator: "\n"), fixes)
    }

    /// 只剔除 Gutenberg 目录（CONTENTS 后的点线引导条目），**保留章节标题**——
    /// 章节标题（CHAPTER I / PLAYING PILGRIMS 等）是有意义的内容，不应删掉。
    public static func stripTOC(_ text: String) -> (text: String, fixes: [TextFix]) {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var fixes: [TextFix] = []

        // 1) CONTENTS 后的目录条目（点线引导 "...." 或 末尾页码）剔除；
        //    允许条目间穿插空行（CONTENTS 后常见空一行）
        if let contentsIdx = lines.firstIndex(where: { isContentsLine($0) }) {
            var end = contentsIdx + 1
            while end < lines.count {
                let t = lines[end].trimmingCharacters(in: .whitespaces)
                if isTOCEntry(t) || t.isEmpty { end += 1 } else { break }
            }
            if end > contentsIdx + 1 {
                fixes.append(TextFix(kind: .skipTOC,
                                     original: "\(lines[contentsIdx].trimmingCharacters(in: .whitespaces).prefix(20)) 起 \(end - contentsIdx - 1) 行目录",
                                     repaired: "（已跳过）", paraIndex: 0))
                lines.removeSubrange((contentsIdx + 1)..<end)
            }
        }

        // 注：章节标题（CHAPTER I / PLAYING PILGRIMS 等）一律保留，不做剔除。
        return (lines.joined(separator: "\n"), fixes)
    }

    /// CONTENTS 标题行（可带尾随句点/空格）。
    private static func isContentsLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).uppercased()
        return t == "CONTENTS" || t == "CONTENTS."
    }

    /// 目录条目：短行且含 ≥3 个连续点（Gutenberg 点线引导），或末尾为页码（1~4 位数字）。
    private static func isTOCEntry(_ t: String) -> Bool {
        guard !t.isEmpty, t.count <= 80 else { return false }
        if t.contains("...") { return true }
        if t.count <= 60, t.last?.isNumber == true, t.contains(where: { $0.isNumber }) {
            // 末尾数字 + 行内无句末标点 → 视为目录页码行
            return !t.contains { ".!?。！？".contains($0) }
        }
        return false
    }

    /// 过滤常见网文垃圾尾巴与平台水印标记（如「（本章完）」、「【求月票】」等）。
    public static func stripWebNovelNoise(_ text: String) -> (text: String, fixes: [TextFix]) {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var fixes: [TextFix] = []
        let noisePatterns = [
            "^\\s*[（(【\\[]?\\s*(?:本章完|求月票|求推荐票|作者有话说|未完待续|请翻页|点击下一页|加入书架|投推荐票|手机用户请浏览).*$",
            "^\\s*[-=~_*]{4,}\\s*$"
        ]
        let regexes = noisePatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
        var kept: [String] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let ns = trimmed as NSString
            let isNoise = regexes.contains { $0.firstMatch(in: trimmed, options: [], range: NSRange(location: 0, length: ns.length)) != nil }
            if isNoise {
                fixes.append(TextFix(kind: .stripBoilerplate, original: "\(trimmed.prefix(30))…", repaired: "（已剔除网文噪音）", paraIndex: 0))
            } else {
                kept.append(line)
            }
        }
        return (kept.joined(separator: "\n"), fixes)
    }

    // MARK: - L3 长句拆分

    /// 中文句末语气词：拆在其后。
    private static let sentenceParticles: Set<Character> = Array("吗呢吧啊呀嘛哦啦哟哈呵").reduce(into: Set<Character>()) { $0.insert($1) }
    /// 结构/动态助词：拆在其后（“他轻轻叹了口气” → “他轻轻叹了口气。”）。
    private static let structuralParticles: Set<Character> = Array("了着过地得").reduce(into: Set<Character>()) { $0.insert($1) }
    /// 代词：拆在其前（“…才发生过一样他轻轻…” → “…才发生过一样。”+“他轻轻…”）。
    private static let pronounCutBefore: Set<Character> = Array("他她它这那我你").reduce(into: Set<Character>()) { $0.insert($1) }
    /// 连词/承接词：拆在其前，作为新句开头。
    private static let conjunctions: [String] = [
        "但是", "可是", "然而", "不过", "于是", "接着", "然后", "随后",
        "因此", "所以", "因为", "由于", "虽然", "尽管", "如果", "要是",
        "即使", "无论", "而且", "并且", "同时", "再说", "况且", "总之",
        "结果", "后来", "最后", "终于", "突然", "忽然", "这时", "此刻",
        "原来", "其实", "但", "却",
    ]

    /// 英文句首副词/承接词（拆在其前，天然可作新句开头）。
    private static let englishSentenceAdverbs: [String] = [
        "moreover", "however", "therefore", "meanwhile", "afterwards",
        "finally", "suddenly", "besides", "nonetheless", "nevertheless",
        "thus", "hence", "consequently", "then",
    ]
    /// 英文连词（拆在其前；and/or/nor 风险高仅作兜底）。
    private static let englishConjunctions: [String] = [
        "but", "so", "because", "although", "though", "while", "when",
        "if", "since", "until", "unless", "yet", "after", "before",
        "and", "or", "nor",
    ]

    /// 判断文本以英文为主（无汉字且含 ASCII 字母）。
    private static func isEnglishText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        return !scalars.contains { $0.properties.isIdeographic }
            && scalars.contains { $0.isASCII && Character($0).isLetter }
    }

    /// 把超过 maxChars/maxEnglishChars 的句子按软边界拆短（L3）。
    /// 拆分优先：分号 > 破折号 > 连词/副词从句 > 逗号。
    /// 返回拆分后的句子（首段停顿 0.35s，末段继承原句停顿）与拆分记录。
    public static func splitLongSentences(
        _ parts: [(text: String, pauseAfter: Double)],
        maxChars: Int = 60,
        maxEnglishChars: Int = 140
    ) -> (parts: [(text: String, pauseAfter: Double)], fixes: [TextFix]) {
        guard maxChars >= 15 else { return (parts, []) }
        // 每句所属段落号：pauseAfter>=1.0 的句子是段末
        var paraOf: [Int] = []
        var para = 1
        for p in parts {
            paraOf.append(para)
            if p.pauseAfter >= 1.0 { para += 1 }
        }
        var out: [(text: String, pauseAfter: Double)] = []
        var fixes: [TextFix] = []
        for (i, p) in parts.enumerated() {
            // 英文按 maxEnglishChars，中文按 maxChars
            let limit = isEnglishText(p.text) ? maxEnglishChars : maxChars
            guard p.text.count > limit else { out.append(p); continue }
            let pieces = splitLongText(p.text, maxChars: limit)
            guard pieces.count > 1 else { out.append(p); continue }
            for (k, piece) in pieces.enumerated() {
                out.append((piece, k < pieces.count - 1 ? 0.4 : p.pauseAfter))
            }
            fixes.append(TextFix(kind: .splitLong,
                                 original: p.text,
                                 repaired: pieces.joined(separator: " ｜ "),
                                 paraIndex: paraOf[i]))
        }
        return (out, fixes)
    }

    /// 单句文本按软边界贪心切分，每段 ≤ maxChars，严格保留原作者标点。
    private static func splitLongText(_ text: String, maxChars: Int) -> [String] {
        let chars = Array(text)
        let isEnglish = isEnglishText(text)
        let minChunk = 20
        var pieces: [String] = []
        var start = 0

        /// 单个字符位置上的软边界权重（0 表示非切点）：返回 (权重, 切点位置)。
        func markerWeight(_ pos: Int) -> (Double, Int) {
            let ch = chars[pos]
            if isEnglish {
                if ch == ";" { return (3.0, pos + 1) }
                if ch == "—" || ch == "–" { return (2.8, pos + 1) }
                if ch == ":" { return (2.0, pos + 1) }
                if ch == "," {
                    // 逗号后跟核心连词/承接词（, and / , but / , so / , however / , while...）→ 极高推荐切点
                    var nextIdx = pos + 1
                    while nextIdx < chars.count && chars[nextIdx].isWhitespace { nextIdx += 1 }
                    let nextSnippet = String(chars[nextIdx..<min(nextIdx + 12, chars.count)]).lowercased()
                    let transitionWords = ["and ", "but ", "so ", "yet ", "for ", "nor ", "however", "therefore", "meanwhile", "while ", "whereas ", "because "]
                    if transitionWords.contains(where: { nextSnippet.hasPrefix($0) }) {
                        return (2.2, pos + 1)
                    }
                    return (0.3, pos + 1)
                }
                if ch.isLetter, pos > 0, !chars[pos - 1].isLetter {
                    for adv in englishSentenceAdverbs where pos + adv.count <= chars.count {
                        if String(chars[pos..<(pos + adv.count)]).lowercased() == adv {
                            let after = pos + adv.count
                            if after >= chars.count || !chars[after].isLetter {
                                return (1.5, pos)
                            }
                        }
                    }
                }
            } else {
                if ch == "；" || ch == ";" { return (3.0, pos + 1) }
                if ch == "—" || ch == "–" { return (2.8, pos + 1) }
                if ch == "：" || ch == ":" { return (2.0, pos + 1) }
                if ch == "，" || ch == "," || ch == "、" {
                    var nextIdx = pos + 1
                    while nextIdx < chars.count && chars[nextIdx].isWhitespace { nextIdx += 1 }
                    for cj in conjunctions where nextIdx + cj.count <= chars.count {
                        if String(chars[nextIdx..<(nextIdx + cj.count)]) == cj {
                            return (2.2, pos + 1)
                        }
                    }
                    return (0.5, pos + 1)
                }
                if pos > start {
                    let prev = chars[pos - 1]
                    if sentenceParticles.contains(prev) { return (2.0, pos + 1) }
                    if pronounCutBefore.contains(ch) { return (0.8, pos) }
                    if structuralParticles.contains(prev) { return (0.7, pos + 1) }
                }
            }
            return (-1, pos)
        }

        func finishPiece(_ end: Int) {
            let first = String(chars[start..<end]).trimmingCharacters(in: .whitespaces)
            if !first.isEmpty {
                pieces.append(first)
            }
            start = end
        }

        while chars.count - start > maxChars {
            let windowEnd = min(start + maxChars, chars.count)
            var best = -1
            var bestWeight = -1.0
            // 主窗口 [start+minChunk, windowEnd)：取最高权重标记（并列取最靠后）
            for pos in (start + minChunk)..<windowEnd {
                let (w, cut) = markerWeight(pos)
                if w > 0, w >= bestWeight { bestWeight = w; best = cut }
            }
            // 回看区（超出窗口最多 40 字）：窗口内无标记时取最近的标记，
            // 避免「唯一好切点恰在窗口外」导致整句不拆（如分号在第 92 字、窗口 90）
            if best < 0 {
                let lookEnd = min(windowEnd + 40, chars.count)
                if lookEnd > windowEnd {
                    for pos in windowEnd..<lookEnd {
                        let (w, cut) = markerWeight(pos)
                        if w > 0 { best = cut; break }
                    }
                }
            }
            if best > 0, chars.count - best >= minChunk {
                finishPiece(best)
            } else if !isEnglish, chars.count - start > maxChars + minChunk {
                // 中文无软标记且剩余明显超长：优先英文空格，否则在窗口末端硬切
                var space = -1
                for pos in (start + minChunk)..<windowEnd where chars[pos].isWhitespace { space = pos }
                finishPiece(space > 0 ? space : windowEnd)
            } else {
                // 无软标记（英文一律如此）：保留整句，避免切出难看的短语/单词中断
                break
            }
        }
        finishPiece(chars.count)
        return pieces
    }

    /// 多编码容错读取（支持 UTF-8 / UTF-16 / 中文 GB18030·GBK·Big5 / 日文 Shift-JIS·EUC-JP / Windows-1252 / Latin-1 自动探查）。
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let big5 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
        let shiftJIS = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)))
        let eucJP = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_JP.rawValue)))
        let candidates: [String.Encoding] = [
            .utf8, .utf16LittleEndian, .utf16BigEndian,
            gb18030, big5, shiftJIS, eucJP,
            .windowsCP1252, .isoLatin1, .ascii
        ]
        for enc in candidates {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return ""
    }

    /// 自动从时间轴片段列表中识别章节标记
    public static func detectChapters(segments: [TimedSegment]) -> [ChapterMarker] {
        guard let regex = chapterRegex, !segments.isEmpty else { return [] }
        var chapters: [ChapterMarker] = []
        for seg in segments {
            let t = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = t as NSString
            if regex.firstMatch(in: t, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                let cleanTitle = t.replacingOccurrences(of: "\n", with: " ")
                chapters.append(ChapterMarker(
                    id: chapters.count,
                    title: cleanTitle,
                    startFrame: seg.startFrame,
                    endFrame: seg.endFrame
                ))
            }
        }
        // 校准各章节 endFrame 为下一章起点或末尾
        var calibrated: [ChapterMarker] = []
        for i in 0..<chapters.count {
            let nextStart = (i + 1 < chapters.count) ? chapters[i + 1].startFrame : (segments.last?.endFrame ?? chapters[i].endFrame)
            calibrated.append(ChapterMarker(
                id: chapters[i].id,
                title: chapters[i].title,
                startFrame: chapters[i].startFrame,
                endFrame: max(chapters[i].startFrame, nextStart)
            ))
        }
        return calibrated
    }

    /// 自动从原始句子列表中识别章节以及对应的起止句子索引范围
    public static func detectChaptersFromSentences(sentences: [Sentence]) -> [(chapter: ChapterMarker, range: Range<Int>)] {
        guard let regex = chapterRegex, !sentences.isEmpty else { return [] }
        var rawMarkers: [(index: Int, title: String)] = []
        for (i, s) in sentences.enumerated() {
            let t = s.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let ns = t as NSString
            if regex.firstMatch(in: t, options: [], range: NSRange(location: 0, length: ns.length)) != nil {
                let cleanTitle = t.replacingOccurrences(of: "\n", with: " ")
                rawMarkers.append((i, cleanTitle))
            }
        }
        guard !rawMarkers.isEmpty else { return [] }
        var result: [(chapter: ChapterMarker, range: Range<Int>)] = []
        for (idx, m) in rawMarkers.enumerated() {
            let nextIndex = (idx + 1 < rawMarkers.count) ? rawMarkers[idx + 1].index : sentences.count
            let range = m.index..<nextIndex
            let marker = ChapterMarker(
                id: idx,
                title: m.title,
                startFrame: 0,
                endFrame: 0
            )
            result.append((marker, range))
        }
        return result
    }
}

// MARK: - EPUB 提取（递归层级解析 + OPF 顺序提取 + NSAttributedString 渲染）

public enum EpubExtractor {
    public static func extractText(from url: URL) throws -> String {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bookstream-epub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-o", "-q", url.path, "-d", tmpDir.path]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BookStreamError.unzipFailed("unzip 退出码 \(proc.terminationStatus)")
        }

        let fm = FileManager.default
        let htmlExts: Set<String> = ["html", "xhtml", "htm"]
        var allHtmlFiles: [URL] = []

        if let enumerator = fm.enumerator(at: tmpDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let fileURL as URL in enumerator {
                if htmlExts.contains(fileURL.pathExtension.lowercased()) {
                    let name = fileURL.lastPathComponent.lowercased()
                    if !name.contains("toc") && !name.contains("nav") {
                        allHtmlFiles.append(fileURL)
                    }
                }
            }
        }

        // 自然数字序排序（确保 chapter2 排在 chapter10 之前）
        allHtmlFiles.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

        var fullText = ""
        for file in allHtmlFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                let s = attributed.string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !s.isEmpty { fullText += s + "\n\n" }
            }
        }
        guard !fullText.isEmpty else {
            throw BookStreamError.epubExtractionFailed("未提取到任何可读内容")
        }
        return fullText
    }
}

// MARK: - SRT 解析 / 写出

public enum SrtParser {
    public static func parse(url: URL) throws -> [SubtitleEntry] {
        parse(text: try TextProcessor.readText(url))
    }

    public static func parse(text raw: String) -> [SubtitleEntry] {
        let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        var entries: [SubtitleEntry] = []
        var index = 0
        var i = 0

        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.contains("-->") {
                let nsLine = line as NSString
                let regex = try? NSRegularExpression(
                    pattern: "(\\d{1,2}):(\\d{2}):(\\d{2})[,.]?(\\d{1,3})?"
                )
                let matches = regex?.matches(
                    in: line, options: [],
                    range: NSRange(location: 0, length: nsLine.length)
                ) ?? []
                if matches.count >= 2 {
                    let start = parseTime(match: matches[0], in: nsLine)
                    let end = parseTime(match: matches[1], in: nsLine)

                    var textLines: [String] = []
                    var j = i + 1
                    while j < lines.count {
                        let tl = lines[j].trimmingCharacters(in: .whitespaces)
                        if tl.isEmpty { break }
                        textLines.append(tl)
                        j += 1
                    }

                    // 智能双语字幕识别：区分主要英文行与中文译文行
                    let entryText: String
                    let entryTranslation: String?
                    if textLines.count >= 2 {
                        var enParts: [String] = []
                        var zhParts: [String] = []
                        for tl in textLines {
                            if TextProcessor.hanRatio(of: tl) >= 0.20 {
                                zhParts.append(tl)
                            } else {
                                enParts.append(tl)
                            }
                        }
                        if !enParts.isEmpty && !zhParts.isEmpty {
                            entryText = enParts.joined(separator: " ")
                            entryTranslation = zhParts.joined(separator: " ")
                        } else {
                            entryText = textLines.joined(separator: " ")
                            entryTranslation = nil
                        }
                    } else {
                        entryText = textLines.joined(separator: " ")
                        entryTranslation = nil
                    }

                    entries.append(SubtitleEntry(
                        id: index,
                        start: start,
                        end: end,
                        text: entryText,
                        translation: entryTranslation
                    ))
                    index += 1
                    i = j
                    continue
                }
            }
            i += 1
        }
        return entries
    }

    private static func parseTime(match: NSTextCheckingResult, in ns: NSString) -> Double {
        func part(_ idx: Int) -> Int {
            let r = match.range(at: idx)
            guard r.location != NSNotFound else { return 0 }
            return Int(ns.substring(with: r)) ?? 0
        }
        let h = part(1), m = part(2), s = part(3)
        var ms = part(4)
        if ms < 10 { ms *= 100 } else if ms < 100 { ms *= 10 }
        return Double(h * 3600 + m * 60 + s) + Double(ms) / 1000.0
    }
}

// MARK: - ASS / SSA 解析

public enum AssParser {
    public static func parse(url: URL) throws -> [SubtitleEntry] {
        parse(text: try TextProcessor.readText(url))
    }

    public static func parse(text: String) -> [SubtitleEntry] {
        var entries: [SubtitleEntry] = []
        var inEvents = false
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                inEvents = (trimmed == "[Events]")
                continue
            }
            guard inEvents, trimmed.hasPrefix("Dialogue:") else { continue }
            let body = trimmed.dropFirst("Dialogue:".count)

            // ASS 固定前 9 个字段（Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect），
            // 剩余全部为 Text（允许含逗号）。
            var fields: [String] = []
            var rest = Substring(body)
            for _ in 0..<9 {
                if let idx = rest.firstIndex(of: ",") {
                    fields.append(String(rest[..<idx]))
                    rest = rest[rest.index(after: idx)...]
                } else {
                    fields.append(String(rest))
                    rest = ""
                    break
                }
            }
            fields.append(String(rest))
            guard fields.count >= 10 else { continue }
            guard let start = parseTime(fields[1]), let end = parseTime(fields[2]) else { continue }

            let rawText = fields[9]
            // 支持 ASS 内嵌 \N 换行双语拆分
            let parts = rawText.components(separatedBy: "\\N")
            let text = stripTags(parts[0])
            let translation = parts.count > 1 ? stripTags(parts[1]) : nil

            if !text.isEmpty {
                entries.append(SubtitleEntry(
                    id: entries.count,
                    start: start,
                    end: end,
                    text: text,
                    translation: (translation?.isEmpty == false) ? translation : nil
                ))
            }
        }
        return entries
    }

    /// h:mm:ss.cc
    private static func parseTime(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, parts[2].count >= 4 else { return nil }
        let h = Double(parts[0]) ?? 0
        let m = Double(parts[1]) ?? 0
        let secPart = parts[2]
        let secs = Double(secPart.prefix(2)) ?? 0
        let cents = Double(secPart.suffix(2)) ?? 0
        return h * 3600 + m * 60 + secs + cents / 100.0
    }

    /// 剥离 ASS 覆盖标签 {\...} 并把 \N / \n 换行替换为空格。
    private static func stripTags(_ raw: String) -> String {
        var out = ""
        var inTag = false
        for ch in raw {
            if ch == "{" { inTag = true; continue }
            if ch == "}" { inTag = false; continue }
            if !inTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "\\N", with: " ")
            .replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - SRT 写出

public enum SrtWriter {
    public static func write(segments: [TimedSegment], to url: URL) throws {
        var out = ""
        for (i, seg) in segments.enumerated() {
            out += "\(i + 1)\n"
            out += "\(formatTime(seg.start)) --> \(formatTime(seg.end))\n"
            if let tr = seg.translation, !tr.isEmpty {
                out += seg.text + "\n" + tr + "\n\n"
            } else {
                out += seg.text + "\n\n"
            }
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func formatTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        let h = ms / 3_600_000
        let m = (ms % 3_600_000) / 60_000
        let s = (ms % 60_000) / 1000
        let milli = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, milli)
    }
}

// MARK: - ASS 写出（带高亮色样式，供外部播放器/工具使用）

public enum AssWriter {
    /// 生成带样式的 ASS 字幕：PrimaryColour 使用所选高亮色（ASS 颜色序为 &HBBGGRR&）。
    public static func write(segments: [TimedSegment], highlight: CaptionColor, to url: URL) throws {
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: 1920
        PlayResY: 1080
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,PingFang SC,72,&H\(assColor(highlight))&,&H000000&,&H000000&,&H96000000&,1,0,0,0,100,100,0,0,1,2,2,2,120,120,80,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        """
        for seg in segments {
            if let tr = seg.translation, !tr.isEmpty {
                let escapedText = escape(seg.text)
                let escapedTr = escape(tr)
                out += "\nDialogue: 0,\(assTime(seg.start)),\(assTime(seg.end)),Default,,0,0,0,,\(escapedText)\\N{\\fs46\\c&HE0E0E0&}\(escapedTr)"
            } else {
                out += "\nDialogue: 0,\(assTime(seg.start)),\(assTime(seg.end)),Default,,0,0,0,,\(escape(seg.text))"
            }
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    /// h:mm:ss.cc
    private static func assTime(_ t: Double) -> String {
        let total = Int((t * 100).rounded())
        let h = total / 360_000
        let m = (total % 360_000) / 6_000
        let s = (total % 6_000) / 100
        let cs = total % 100
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    /// ASS 颜色：&HBBGGRR&（蓝绿红序）
    private static func assColor(_ c: CaptionColor) -> String {
        let r = Int((c.red * 255).rounded())
        let g = Int((c.green * 255).rounded())
        let b = Int((c.blue * 255).rounded())
        return String(format: "%02X%02X%02X", b, g, r)
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "{", with: "(")
            .replacingOccurrences(of: "}", with: ")")
            .replacingOccurrences(of: "\n", with: "\\N")
    }
}

// MARK: - 章节列表写出（支持 YouTube / B站 / 播客 标准时间戳格式）

public enum ChapterWriter {
    public static func write(chapters: [ChapterMarker], to url: URL) throws {
        var out = ""
        for ch in chapters {
            out += "\(formatTimestamp(ch.start)) \(ch.title)\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func formatTimestamp(_ t: Double) -> String {
        let totalSecs = Int(t.rounded(.down))
        let h = totalSecs / 3600
        let m = (totalSecs % 3600) / 60
        let s = totalSecs % 60
        if h > 0 {
            return String(format: "%02d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%02d:%02d", m, s)
        }
    }
}

