import Foundation

// MARK: - 数据模型

/// 书籍分句后的一个句子。
public struct Sentence: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
    }
}

/// 字幕条目（毫秒级时间轴）。
public struct SubtitleEntry: Identifiable, Sendable, Equatable {
    public let id: Int
    public let start: Double
    public let end: Double
    public let text: String

    public init(id: Int, start: Double, end: Double, text: String) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
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
    public let startFrame: Int64
    public let endFrame: Int64

    public var start: Double { Double(startFrame) / AudioFormat.sampleRate }
    public var end: Double { Double(endFrame) / AudioFormat.sampleRate }
    public var duration: Double { end - start }

    public init(id: Int, text: String, startFrame: Int64, endFrame: Int64) {
        self.id = id
        self.text = text
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

public enum TextProcessor {

    /// 标点分句：以句号/问号/感叹号/换行为边界；逗号、分号仅作句中停顿。
    /// 合并过短碎片（< 2 字符）至上一句，保证语流连贯。
    public static func splitSentences(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var pendingTerminator = ""
        let boundaries: Set<Character> = [".", "!", "?", "。", "！", "？", "\n"]

        func flush() {
            let s = (current + pendingTerminator)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sentences.append(s) }
            current = ""
            pendingTerminator = ""
        }

        for ch in text {
            if ch == "\n" {
                if !current.isEmpty || !pendingTerminator.isEmpty { flush() }
                continue
            }
            if boundaries.contains(ch) {
                // 句末标点（可连续，如 ... 或 !?）
                pendingTerminator.append(ch)
                continue
            }
            if !pendingTerminator.isEmpty {
                // 非标点字符出现 → 上一句结束
                flush()
            }
            if ch == " " && current.isEmpty { continue }
            current.append(ch)
        }
        if !current.isEmpty || !pendingTerminator.isEmpty { flush() }

        // 合并过短碎片
        var merged: [String] = []
        for s in sentences {
            if s.count < 2, let last = merged.last {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    public static func parseBookFile(url: URL) throws -> [Sentence] {
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
        let parts = splitSentences(rawText)
        guard !parts.isEmpty else { throw BookStreamError.unsupportedFile("空文本") }
        return parts.enumerated().map { Sentence(id: $0.offset, text: $0.element) }
    }

    /// 多编码容错读取（UTF-8 / UTF-16 / Latin-1 兜底）。
    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let candidates: [String.Encoding] = [
            .utf8, .utf16LittleEndian, .utf16BigEndian, .isoLatin1, .ascii
        ]
        for enc in candidates {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return ""
    }
}

// MARK: - EPUB 提取（系统内置 unzip + NSAttributedString HTML 渲染，严禁手写正则）

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

        let htmlExts: Set<String> = ["html", "xhtml", "htm"]
        let files = try FileManager.default.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { htmlExts.contains($0.pathExtension.lowercased()) }
        .filter {
            let name = $0.lastPathComponent.lowercased()
            return !name.contains("toc") && !name.contains("nav")
        }
        .sorted { $0.path < $1.path }

        var fullText = ""
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                .documentType: NSAttributedString.DocumentType.html,
                .characterEncoding: String.Encoding.utf8.rawValue,
            ]
            if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
                let s = attributed.string
                if !s.isEmpty { fullText += s + "\n" }
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
                    entries.append(SubtitleEntry(
                        id: index,
                        start: start,
                        end: end,
                        text: textLines.joined(separator: " ")
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

            let text = stripTags(fields[9])
            if !text.isEmpty {
                entries.append(SubtitleEntry(
                    id: entries.count, start: start, end: end, text: text
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
            out += seg.text + "\n\n"
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
            out += "\nDialogue: 0,\(assTime(seg.start)),\(assTime(seg.end)),Default,,0,0,0,,\(escape(seg.text))"
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
