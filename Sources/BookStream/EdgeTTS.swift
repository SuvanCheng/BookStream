import Foundation
import AVFoundation

/// 微软广播级 Neural 语音模型定义（高质量 48kHz/24kHz 原声录制）。
public struct EdgeVoice: Sendable, Identifiable, Hashable {
    public let id: String          // 如 "en-US-ChristopherNeural"
    public let displayName: String // 如 "Christopher (美音·有声书男主)"
    public let language: String    // 如 "en-US", "zh-CN"
    public let gender: String      // "男声" / "女声"
    public let tag: String         // 如 "有声书首选", "磁性播音"

    public init(id: String, displayName: String, language: String, gender: String, tag: String) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.gender = gender
        self.tag = tag
    }
}

/// 微软广播级 Neural 语音引擎（免 API Key，原生支持全球顶流有声书主播音色）。
public final class EdgeTTS: @unchecked Sendable {

    public static let shared = EdgeTTS()

    /// 内置精选全球高保真有声书音色库
    public static let popularVoices: [EdgeVoice] = [
        // ---- 中文顶级主播 ----
        EdgeVoice(id: "zh-CN-YunxiNeural", displayName: "云希 (顶级沉稳·有声书男神)", language: "zh-CN", gender: "男声", tag: "有声书首选"),
        EdgeVoice(id: "zh-CN-YunjianNeural", displayName: "云健 (影视解说·生动激昂)", language: "zh-CN", gender: "男声", tag: "解说热门"),
        EdgeVoice(id: "zh-CN-XiaoxiaoNeural", displayName: "晓晓 (温婉知性·故事女声)", language: "zh-CN", gender: "女声", tag: "经典女播"),
        EdgeVoice(id: "zh-CN-YunyangNeural", displayName: "云扬 (专业新闻·沉着大气)", language: "zh-CN", gender: "男声", tag: "播音主持"),
        EdgeVoice(id: "zh-CN-XiaoyiNeural", displayName: "晓伊 (清亮少女·活泼自然)", language: "zh-CN", gender: "女声", tag: "轻快对话"),
        EdgeVoice(id: "zh-CN-liaoning-XiaobeiNeural", displayName: "晓北 (东北方言·亲切幽默)", language: "zh-CN", gender: "女声", tag: "方言特色"),
        EdgeVoice(id: "zh-CN-shaanxi-XiaoniNeural", displayName: "晓妮 (陕西方言·质朴生动)", language: "zh-CN", gender: "女声", tag: "方言特色"),
        EdgeVoice(id: "zh-HK-HiuGaaiNeural", displayName: "晓佳 (粤语女声·纯正自然)", language: "zh-HK", gender: "女声", tag: "粤语精选"),
        EdgeVoice(id: "zh-TW-HsiaoChenNeural", displayName: "晓臻 (台湾国语·温柔清新)", language: "zh-TW", gender: "女声", tag: "国语精选"),

        // ---- 英文顶级主播 (听力巴士主推) ----
        EdgeVoice(id: "en-US-ChristopherNeural", displayName: "Christopher (美音·经典叙述男神)", language: "en-US", gender: "男声", tag: "有声书首选"),
        EdgeVoice(id: "en-US-GuyNeural", displayName: "Guy (美音·磁性沉稳男声)", language: "en-US", gender: "男声", tag: "电台质感"),
        EdgeVoice(id: "en-US-JennyNeural", displayName: "Jenny (美音·优雅温润女声)", language: "en-US", gender: "女声", tag: "听力精读"),
        EdgeVoice(id: "en-US-AriaNeural", displayName: "Aria (美音·清澈知性女声)", language: "en-US", gender: "女声", tag: "自然叙事"),
        EdgeVoice(id: "en-US-EricNeural", displayName: "Eric (美音·阳光青年男声)", language: "en-US", gender: "男声", tag: "青年角色"),
        EdgeVoice(id: "en-GB-RyanNeural", displayName: "Ryan (英音·英伦绅士男声)", language: "en-GB", gender: "男声", tag: "英伦经典"),
        EdgeVoice(id: "en-GB-SoniaNeural", displayName: "Sonia (英音·典雅庄重女声)", language: "en-GB", gender: "女声", tag: "英音精读"),
        EdgeVoice(id: "en-AU-WilliamNeural", displayName: "William (澳音·沉着自然男声)", language: "en-AU", gender: "男声", tag: "多国口音"),

        // ---- 其他热门外语 ----
        EdgeVoice(id: "ja-JP-NanamiNeural", displayName: "Nanami (日语·温柔女声)", language: "ja-JP", gender: "女声", tag: "日语精选"),
        EdgeVoice(id: "ja-JP-KeitaNeural", displayName: "Keita (日语·青年男声)", language: "ja-JP", gender: "男声", tag: "日语精选"),
        EdgeVoice(id: "ko-KR-SunHiNeural", displayName: "SunHi (韩语·自然女声)", language: "ko-KR", gender: "女声", tag: "韩语精选"),
        EdgeVoice(id: "fr-FR-DeniseNeural", displayName: "Denise (法语·浪漫女声)", language: "fr-FR", gender: "女声", tag: "法语精选"),
        EdgeVoice(id: "de-DE-ConradNeural", displayName: "Conrad (德语·沉着男声)", language: "de-DE", gender: "男声", tag: "德语精选"),
        EdgeVoice(id: "es-ES-AlvaroNeural", displayName: "Alvaro (西语·醇厚男声)", language: "es-ES", gender: "男声", tag: "西语精选")
    ]

    public init() {}

    private static func findPythonURL() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let envPy = home.appendingPathComponent(".bookstream/kokoro-env/bin/python3")
        if FileManager.default.fileExists(atPath: envPy.path) {
            return envPy
        }
        if FileManager.default.fileExists(atPath: "/opt/homebrew/bin/python3.12") {
            return URL(fileURLWithPath: "/opt/homebrew/bin/python3.12")
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    /// 检查 Python edge-tts 运行环境是否就绪
    public static func isAvailable() -> Bool {
        let proc = Process()
        proc.executableURL = findPythonURL()
        proc.arguments = ["-c", "import edge_tts; print('ok')"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// 单句高保真抓轨合成
    public func render(text: String, voiceId: String, rate: Float) throws -> [AVAudioPCMBuffer] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let outMP3 = tmpDir.appendingPathComponent("edge-\(UUID().uuidString).mp3")
        defer { try? fm.removeItem(at: outMP3) }

        // 语速换算（rate 0.4 为基准 1.0x，每 0.1 偏差换算为百分比）
        let rateOffset = Int(round((rate - 0.4) * 200)) // 如 0.5 -> +20%, 0.3 -> -20%
        let rateStr = rateOffset >= 0 ? "+\(rateOffset)%" : "\(rateOffset)%"

        let proc = Process()
        proc.executableURL = Self.findPythonURL()
        proc.arguments = [
            "-m", "edge_tts",
            "--voice", voiceId,
            "--text", trimmed,
            "--rate", rateStr,
            "--write-media", outMP3.path
        ]
        let errPipe = Pipe()
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0, fm.fileExists(atPath: outMP3.path) else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "未知错误"
            throw BookStreamError.audioRenderFailed("微软 Neural 合成失败: \(errMsg.prefix(120))")
        }

        let audioFile = try AVAudioFile(forReading: outMP3)
        var buffers: [AVAudioPCMBuffer] = []
        while audioFile.framePosition < audioFile.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: 4096) else { break }
            try audioFile.read(into: buf)
            if buf.frameLength == 0 { break }
            buffers.append(buf)
        }
        guard !buffers.isEmpty else {
            throw BookStreamError.audioRenderFailed("微软 Neural 未产出音频数据")
        }
        return buffers
    }
}
