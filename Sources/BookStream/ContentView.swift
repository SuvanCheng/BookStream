import SwiftUI
import AppKit
import AVKit
import AVFoundation
import UniformTypeIdentifiers
import os

// MARK: - 应用状态模型（全部 UI 状态变更严格 @MainActor）

@MainActor
final class AppModel: ObservableObject {

    enum ExportMode: String, CaseIterable, Identifiable {
        case srt   = "SRT 字幕"
        case audio = "WAV 无损"
        case m4b   = "M4B 有声书"
        case video = "字幕视频"
        var id: String { rawValue }
    }

    /// 高亮色调色盘
    static let paletteColors: [CaptionColor] = [
        .vividOrange, .red, .yellow, .green, .cyan, .blue, .purple, .pink, .white,
    ]

    // 输入
    @Published var inputKind: InputKind?
    @Published var inputURL: URL?

    // 设置
    /// 背景音乐预设（涵盖 macOS 经典大自然白噪音与和弦轻音乐）
    enum BGMPreset: String, CaseIterable, Identifiable {
        case none           = "关闭"
        case gentlePiano    = "舒缓和弦氛围乐 (内置)"
        case oceanWaves     = "海浪波涛·潮汐声 (内置)"
        case rainAmbience   = "沉浸雨声·雨滴白噪音 (内置)"
        case fireplace      = "温暖壁炉·柴火噼啪 (内置)"
        case mountainStream = "山间小溪·潺潺流水 (内置)"
        case forestWind     = "林间微风·自然呼吸 (内置)"
        case darkNoise      = "暗噪音·深沉静谧 (内置)"
        case pinkNoise      = "平衡粉噪·清爽专注 (内置)"
        case custom         = "自选音频文件..."
        var id: String { rawValue }
    }

    @Published var speechRate: Float = 0.4
    @Published var pauseScale: Float = 1.4   // 句间/段间停顿倍数（默认 1.4x）
    @Published var exportMode: ExportMode = .video
    @Published var highlightColor: CaptionColor = .vividOrange
    @Published var backgroundTheme: BackgroundTheme = .pureBlack
    @Published var visualizerStyle: VisualizerStyle = .waveRibbon // 动态声波挂件样式（Siri 平滑光带 / 经典律动柱 / 关闭）
    @Published var showVisualizer: Bool = true
    @Published var enableKaraoke: Bool = true
    @Published var enableIntroOutro: Bool = false // 优雅片头封面卡与片尾淡入淡出（1.5s，默认关闭）
    @Published var enableParticles: Bool = true  // 深空星尘微光微粒背景
    @Published var enableVocalWarmth: Bool = true // 录音棚电台级人声温暖度提升
    @Published var autoGenerateCover: Bool = false // 视频渲染同时自动导出高清封面图（cover.jpg，默认关闭）
    @Published var subtitleFont: SubtitleFont = .systemDefault
    @Published var videoAspectRatio: VideoAspectRatio = .portrait9_16 // 默认 9:16 竖屏短视频
    @Published var videoQuality: VideoQuality = .p480
    @Published var videoCodec: VideoCodec = .hevc // 默认 H.265 / HEVC 硬件加速
    @Published var exportByChapter: Bool = false
    @Published var frameRate: Int = 24   // 视频帧率（默认 24 fps 电影感）

    // 背景音乐（BGM 混音 + 智能侧链压限）
    @Published var bgmPreset: BGMPreset = .none
    @Published var bgmURL: URL?
    @Published var bgmVolume: Float = 0.03 // 默认 3% 舒适微弱背景音
    @Published var enableDucking: Bool = true

    var videoResolution: VideoResolution {
        VideoResolution.make(aspectRatio: videoAspectRatio, quality: videoQuality)
    }

    // 全球顶级 AI 语音引擎体系（Kokoro-82M 离线神经网络 / 微软 Edge-TTS / 自定义 API，UserDefaults 记忆持久化）
    @Published var selectedTTSEngine: TTSEngineType = AppModel.loadSelectedTTSEngine()
    @Published var selectedKokoroVoiceID: String = AppModel.loadSelectedKokoroVoiceID()
    @Published var selectedEdgeVoiceID: String = AppModel.loadSelectedEdgeVoiceID()
    @Published var customAPISettings: CustomAPISettings = AppModel.loadCustomAPISettings()

    // 已有音频复用（字幕输入 + 视频模式时，可跳过 TTS）
    @Published var useExistingAudio = false
    @Published var companionAudioURL: URL?
    @Published var splitLongSentences = true   // L3：超长句（>60 字/140词）按语法从句软边界拆短

    // 字幕旁白溢出策略（语音长于字幕窗口时：顺延 / 截断）
    @Published var subtitleOverflowPolicy: SubtitleOverflowPolicy = .extend

    // 水印（视频导出用，UserDefaults 持久化）
    @Published var watermark: WatermarkSettings = AppModel.loadWatermark()

    // 中英双语字幕配置（UserDefaults 持久化）
    @Published var translationSettings: TranslationSettings = AppModel.loadTranslationSettings()

    // 运行状态
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var logLines: [String] = []
    @Published var previewURL: URL?
    @Published var errorMessage: String?

    private var pipelineTask: Task<Void, Never>?
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var hasUserPickedVoice: Bool = AppModel.loadHasUserPickedVoice()
    private var previewAudioPlayer: AVAudioPlayer?
    private var previewSound: NSSound?
    /// 导出计时与进度日志状态（每次导出开始与阶段切换时重置）。
    private var exportStartTime = Date()
    private var phaseStartTime = Date()
    private var lastLoggedPercent = -1

    // MARK: - 派生信息

    var summaryText: String {
        guard let input = inputKind else { return "尚未载入文件" }
        switch input {
        case .book(let title, let sentences):
            let chars = sentences.reduce(0) { $0 + $1.text.count }
            let hanRatio = Self.hanRatio(of: sentences.prefix(200).map(\.text).joined())
            let audioEst = Self.estimateAudioDuration(chars: chars, hanRatio: hanRatio, rate: speechRate)
            let genEst = Self.estimateGenerationTime(chars: chars, audioDur: audioEst, resolution: videoResolution)
            return "\(title) · \(sentences.count) 句 · \(chars) 字 · 音频约 \(Self.formatDuration(audioEst)) · 生成约 \(Self.formatDuration(genEst))"
        case .subtitles(let title, let entries):
            let dur = entries.last.map { $0.end } ?? 0
            let isBilingual = entries.contains { $0.translation != nil && !$0.translation!.isEmpty }
            let tag = isBilingual ? " · 中英双语" : ""
            return "\(title) · \(entries.count) 条\(tag) · 总时长 \(Self.formatDuration(dur))"
        }
    }

    /// 文本中汉字占比（预估语速用）。
    private static func hanRatio(of text: String) -> Double {
        let scalars = text.unicodeScalars
        guard !scalars.isEmpty else { return 0 }
        let han = scalars.filter { $0.properties.isIdeographic }.count
        return Double(han) / Double(scalars.count)
    }

    /// 预估音频时长（秒）：中文约 4.8 字/秒、英文约 17 字/秒（基准 0.5 语速），
    /// 语速缩放：1 + (0.5 - rate) * 1.2。
    private static func estimateAudioDuration(chars: Int, hanRatio: Double, rate: Float) -> Double {
        guard chars > 0 else { return 0 }
        let base = hanRatio > 0.2 ? 4.8 : 17.0
        let rateScale = 1.0 + Double(0.5 - rate) * 1.2
        return Double(chars) / base * rateScale
    }

    /// 预估生成耗时（秒）：TTS 合成 + 视频渲染。
    /// 基准（实测校准）：Kokoro/Edge 神经引擎约 600 字/秒；视频渲染约 20× 实时（480p），
    /// 随分辨率像素数反比缩放（1080p≈9×，4K≈2×）。
    private static func estimateGenerationTime(chars: Int, audioDur: Double, resolution: VideoResolution) -> Double {
        let tts = Double(chars) / 600.0
        let px = Double(resolution.width * resolution.height)
        let videoRealtime = 20.0 * (921_600.0 / max(px, 1))   // 480p 像素 = 921600
        let video = audioDur / max(videoRealtime, 1)
        return tts + video
    }

    private static func formatDuration(_ s: Double) -> String {
        let total = Int(s.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let sec = total % 60
        if h > 0 { return "\(h)h \(m)m \(sec)s" }
        return "\(m)m \(sec)s"
    }

    // MARK: - 生命周期

    func initializeApp() {
        log("环境: \(Self.environmentSummary())")
        let voiceName: String
        switch selectedTTSEngine {
        case .kokoro:
            voiceName = KokoroTTS.popularVoices.first(where: { $0.id == selectedKokoroVoiceID })?.displayName ?? selectedKokoroVoiceID
            log("AI 引擎就绪（当前使用 Kokoro-82M 顶级离线神经模型 · \(voiceName)）")
        case .edgeTTS:
            voiceName = EdgeTTS.popularVoices.first(where: { $0.id == selectedEdgeVoiceID })?.displayName ?? selectedEdgeVoiceID
            log("AI 引擎就绪（当前使用 微软广播级 Neural 原声 · \(voiceName)）")
        case .customAPI:
            log("AI 引擎就绪（当前使用 自定义大模型 API · \(customAPISettings.provider.label)）")
        }
    }

    /// 按内容语言自动选择最佳配音（若用户已手动选择过喜爱的音色，则保持记忆不覆盖）。
    func selectDefaultVoice(for text: String?) {
        guard !hasUserPickedVoice else { return }
        let language = Self.detectLanguage(of: text)
        if language == "zh-CN" {
            selectedKokoroVoiceID = "zm_yunxi"
            selectedEdgeVoiceID = "zh-CN-YunxiNeural"
        } else if language == "ja-JP" {
            selectedKokoroVoiceID = "jf_alpha"
            selectedEdgeVoiceID = "ja-JP-NanamiNeural"
        } else {
            selectedKokoroVoiceID = "af_heart"
            selectedEdgeVoiceID = "en-US-ChristopherNeural"
        }
    }

    /// 文字脚本/重音启发式语言检测（决定默认配音语言）。
    private static func detectLanguage(of text: String?) -> String {
        guard let text, !text.isEmpty else { return "en-US" }
        let scalars = Array(String(text.prefix(6000)).unicodeScalars)
        var script = Array(repeating: 0, count: 9)
        var umlaut = 0, acute = 0, tilde = 0, ring = 0, slashO = 0, eszett = 0
        for sc in scalars {
            switch sc.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: script[0] += 1  // CJK
            case 0x3040...0x309F, 0x30A0...0x30FF: script[1] += 1  // 假名
            case 0xAC00...0xD7AF: script[2] += 1                   // 谚文
            case 0x0400...0x04FF: script[3] += 1                   // 西里尔
            case 0x0600...0x06FF: script[4] += 1                   // 阿拉伯
            case 0x0590...0x05FF: script[5] += 1                   // 希伯来
            case 0x0E00...0x0E7F: script[6] += 1                   // 泰文
            case 0x0900...0x097F: script[7] += 1                   // 天城文
            case 0x0370...0x03FF: script[8] += 1                   // 希腊
            case 0x00E4, 0x00F6, 0x00FC, 0x00C4, 0x00D6, 0x00DC: umlaut += 1
            case 0x00DF: eszett += 1
            case 0x00E9, 0x00E8, 0x00EA, 0x00C9, 0x00C8, 0x00CA,
                 0x00E0, 0x00E2, 0x00F9, 0x00FB, 0x00E7, 0x00C7: acute += 1
            case 0x00F1, 0x00D1, 0x00E3, 0x00F5: tilde += 1
            case 0x00E5, 0x00C5: ring += 1
            case 0x00F8, 0x00D8: slashO += 1
            default: break
            }
        }
        let threshold = max(scalars.count / 10, 1)
        if script[0] > threshold { return "zh-CN" }
        if script[1] > threshold { return "ja-JP" }
        if script[2] > threshold { return "ko-KR" }
        if script[3] > threshold { return "ru-RU" }
        if script[4] > threshold { return "ar-SA" }
        if script[5] > threshold { return "he-IL" }
        if script[6] > threshold { return "th-TH" }
        if script[7] > threshold { return "hi-IN" }
        if script[8] > threshold { return "el-GR" }
        if eszett > 0 || umlaut > acute { return "de-DE" }
        if tilde > 0 { return "es-ES" }
        if acute > 0 { return "fr-FR" }
        if ring > 0 { return "da-DK" }
        if slashO > 0 { return "nb-NO" }
        return "en-US"
    }

    private static func languageName(_ code: String) -> String {
        switch code {
        case "zh-CN": return "中文"
        case "ja-JP": return "日语"
        case "ko-KR": return "韩语"
        case "ru-RU": return "俄语"
        case "ar-SA": return "阿拉伯语"
        case "he-IL": return "希伯来语"
        case "th-TH": return "泰语"
        case "hi-IN": return "印地语"
        case "el-GR": return "希腊语"
        case "de-DE": return "德语"
        case "es-ES": return "西班牙语"
        case "fr-FR": return "法语"
        case "da-DK": return "丹麦语"
        case "nb-NO": return "挪威语"
        default: return "英语"
        }
    }



    /// 将 PCM 音频缓冲完整写入临时 WAV 文件（确保文件句柄关闭、Header 写入完整）
    nonisolated private static func writeBuffersToTempWav(_ buffers: [AVAudioPCMBuffer]) throws -> URL {
        guard let first = buffers.first else {
            throw BookStreamError.audioRenderFailed("无有效音频数据")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID().uuidString).wav")
        let sr = first.format.sampleRate
        let file = try AVAudioFile(forWriting: tmp, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        for buf in buffers {
            try file.write(from: buf)
        }
        return tmp
    }

    /// 播放试听音频（双重引擎保证：优先 AVAudioPlayer，回退 NSSound）
    @MainActor
    private func playPreviewAudio(at url: URL, label: String) {
        // 先停掉上一段试听，避免多重并发播放
        self.previewAudioPlayer?.stop()
        self.previewSound?.stop()

        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            player.volume = 1.0
            if player.play() {
                self.previewAudioPlayer = player
                self.log("\(label)播放中")
            } else if let sound = NSSound(contentsOf: url, byReference: true), sound.play() {
                self.previewSound = sound
                self.log("\(label)播放中")
            } else {
                self.log("\(label)播放未启动（请检查系统音频输出设备与音量）")
            }
        } catch {
            if let sound = NSSound(contentsOf: url, byReference: true), sound.play() {
                self.previewSound = sound
                self.log("\(label)播放中")
            } else {
                self.log("\(label)播放失败: \(error.localizedDescription)")
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// 试听 Kokoro-82M 本地神经音色
    func previewKokoroVoice() {
        let voiceId = selectedKokoroVoiceID
        let rate = speechRate
        log("正在连接 Kokoro-82M 本地试听（\(voiceId)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let sampleText: String
                if voiceId.hasPrefix("z") {
                    sampleText = "欢迎收听听力巴士。这是一段 Kokoro 本地神经网络语音的试听。"
                } else if voiceId.hasPrefix("j") {
                    sampleText = "こんにちは。これはKokoro音声プレビューです。"
                } else {
                    sampleText = "Welcome to Listening Bus. This is a preview of Kokoro local neural voice."
                }
                let buffers = try KokoroTTS.shared.render(text: sampleText, voice: voiceId, rate: rate)
                let tmp = try Self.writeBuffersToTempWav(buffers)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.playPreviewAudio(at: tmp, label: "Kokoro 音色试听（\(voiceId)）")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("Kokoro 试听失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// 试听微软 Neural 广播级音色
    func previewEdgeVoice() {
        let voiceId = selectedEdgeVoiceID
        let rate = speechRate
        log("正在连接微软 Neural 试听（\(voiceId)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let sampleText = voiceId.hasPrefix("zh") ? "欢迎收听听力巴士。这是一段微软广播级神经语音的试听。" : "Welcome to Listening Bus. This is a preview of Microsoft Neural broadcast voice."
                let buffers = try EdgeTTS.shared.render(text: sampleText, voiceId: voiceId, rate: rate)
                let tmp = try Self.writeBuffersToTempWav(buffers)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.playPreviewAudio(at: tmp, label: "微软 Neural 音色试听（\(voiceId)）")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("微软 Neural 试听失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// 试听自定义 API 音色
    func previewCustomAPIVoice() {
        let settings = customAPISettings
        let rate = speechRate
        log("正在连接自定义 API 试听（\(settings.provider.label) · \(settings.model)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let buffers = try CustomAPITTS.shared.render(text: "Welcome to Listening Bus. 这是自定义 API 语音接口的试听样例。", settings: settings, rate: rate)
                let tmp = try Self.writeBuffersToTempWav(buffers)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.playPreviewAudio(at: tmp, label: "自定义 API 试听")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("自定义 API 试听失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func loadInput(url: URL) async {
        let t0 = Date()
        log("解析输入: \(url.lastPathComponent)（\(url.path)）")
        errorMessage = nil
        do {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "txt", "epub":
                let splitLong = splitLongSentences
                let (sentences, fixes) = try await Task.detached(priority: .userInitiated) {
                    try TextProcessor.parseBookFile(url: url, splitLong: splitLong)
                }.value
                inputKind = .book(
                    title: url.deletingPathExtension().lastPathComponent,
                    sentences: sentences
                )
                let chars = sentences.reduce(0) { $0 + $1.text.count }
                log("书籍解析完成: \(sentences.count) 句 / \(chars) 字（\(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
                let han = Self.hanRatio(of: sentences.prefix(200).map(\.text).joined())
                let audioEst = Self.estimateAudioDuration(chars: chars, hanRatio: han, rate: speechRate)
                let genEst = Self.estimateGenerationTime(chars: chars, audioDur: audioEst, resolution: videoResolution)
                log("预估: 音频时长约 \(Self.formatDuration(audioEst)) · 生成耗时约 \(Self.formatDuration(genEst))（TTS 约 \(Self.formatDuration(Double(chars) / 500.0)) + 视频渲染约 \(Self.formatDuration(audioEst / max(20.0 * (921_600.0 / Double(videoResolution.width * videoResolution.height)), 1)))）")
                logTextFixes(fixes)
            case "srt":
                let entries = try await Task.detached(priority: .userInitiated) {
                    try SrtParser.parse(url: url)
                }.value
                guard !entries.isEmpty else { throw BookStreamError.unsupportedFile("空字幕") }
                inputKind = .subtitles(
                    title: url.deletingPathExtension().lastPathComponent,
                    entries: entries
                )
                let bilingualCount = entries.filter { $0.translation != nil && !$0.translation!.isEmpty }.count
                if bilingualCount > 0 {
                    log("SRT 解析完成: \(entries.count) 条（自动识别中英双语 \(bilingualCount) 条，耗时 \(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
                } else {
                    log("SRT 解析完成: \(entries.count) 条（\(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
                }
                if let autoAudio = Self.findCompanionAudio(for: url) {
                    companionAudioURL = autoAudio
                    useExistingAudio = true
                    log("  💡 已自动检测并关联同名音频: \(autoAudio.lastPathComponent)（已启用「复用音频·跳过TTS」极速渲染）")
                } else {
                    companionAudioURL = nil
                    useExistingAudio = false
                }
            case "ass", "ssa":
                let entries = try await Task.detached(priority: .userInitiated) {
                    try AssParser.parse(url: url)
                }.value
                guard !entries.isEmpty else { throw BookStreamError.unsupportedFile("空字幕") }
                inputKind = .subtitles(
                    title: url.deletingPathExtension().lastPathComponent,
                    entries: entries
                )
                log("ASS/SSA 解析完成: \(entries.count) 条")
                if let autoAudio = Self.findCompanionAudio(for: url) {
                    companionAudioURL = autoAudio
                    useExistingAudio = true
                    log("  💡 已自动检测并关联同名音频: \(autoAudio.lastPathComponent)（已启用「复用音频·跳过TTS」极速渲染）")
                } else {
                    companionAudioURL = nil
                    useExistingAudio = false
                }
            default:
                throw BookStreamError.unsupportedFile(ext)
            }
            inputURL = url
            previewURL = nil

            // 未手动选过声音时，按内容语言自动选择最优自然音色
            if !hasUserPickedVoice {
                let sampleText: String
                switch inputKind {
                case .book(_, let sentences):
                    sampleText = sentences.prefix(40).map(\.text).joined(separator: " ")
                case .subtitles(_, let entries):
                    sampleText = entries.prefix(40).map(\.text).joined(separator: " ")
                case nil:
                    sampleText = ""
                }
                selectDefaultVoice(for: sampleText)
            }
        } catch {
            errorMessage = error.localizedDescription
            log("解析失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 导出

    func startExport() {
        guard let input = inputKind, !isProcessing else { return }

        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        let stamp = Int(Date().timeIntervalSince1970)
        // 文件名格式：书名-音色名-[AI|sys]-语速-停顿x-分辨率-mark|nomark-时间戳.mp4
        // 例：1-danny-[AI]-0.5-1.0x-480p-mark-1787312689.mp4
        let rawTitle = {
            switch input {
            case .book(let t, _): return t
            case .subtitles(let t, _): return t
            }
        }()
        let title = cleanSourceTitle(rawTitle)
        let (voiceCore, voiceTag): (String, String) = {
            switch selectedTTSEngine {
            case .kokoro:
                let raw = KokoroTTS.popularVoices.first { $0.id == selectedKokoroVoiceID }?.displayName.components(separatedBy: " ").first ?? selectedKokoroVoiceID
                return (raw, "[Kokoro]")
            case .edgeTTS:
                let raw = EdgeTTS.popularVoices.first { $0.id == selectedEdgeVoiceID }?.displayName.components(separatedBy: " ").first ?? selectedEdgeVoiceID
                return (raw, "[Edge]")
            case .customAPI:
                let raw = customAPISettings.voice.isEmpty ? customAPISettings.model : customAPISettings.voice
                return (raw, "[API]")
            }
        }()
        let rateStr = String(format: "%.1f", speechRate)
        let pauseStr = String(format: "%.1fx", pauseScale)

        let bgmTag: String = {
            switch bgmPreset {
            case .none:
                return "nobgm"
            case .gentlePiano:
                return "bgm-piano-\(Int(bgmVolume * 100))"
            case .oceanWaves:
                return "bgm-ocean-\(Int(bgmVolume * 100))"
            case .rainAmbience:
                return "bgm-rain-\(Int(bgmVolume * 100))"
            case .fireplace:
                return "bgm-fireplace-\(Int(bgmVolume * 100))"
            case .mountainStream:
                return "bgm-stream-\(Int(bgmVolume * 100))"
            case .forestWind:
                return "bgm-forest-\(Int(bgmVolume * 100))"
            case .darkNoise:
                return "bgm-darknoise-\(Int(bgmVolume * 100))"
            case .pinkNoise:
                return "bgm-pinknoise-\(Int(bgmVolume * 100))"
            case .custom:
                let name = sanitizeFilename(bgmURL?.deletingPathExtension().lastPathComponent ?? "custom")
                return "bgm-\(name)-\(Int(bgmVolume * 100))"
            }
        }()

        let themeTag: String = {
            switch backgroundTheme {
            case .pureBlack: return "pureblack"
            case .darkGradient: return "darkgradient"
            case .charcoal: return "charcoal"
            case .midnightPurple: return "midnight"
            }
        }()

        let aspectTag: String = {
            switch videoAspectRatio {
            case .portrait9_16: return "9x16"
            case .landscape16_9: return "16x9"
            case .square1_1: return "1x1"
            }
        }()

        let codecTag = videoCodec.rawValue // "hevc" 或 "h264"
        let fpsTag = "\(frameRate)fps"
        let resTag = videoResolution.label.lowercased()
        let markTag = watermark.enabled ? "mark" : "nomark"

        // 文件名只给主名（不含扩展名）：保存面板会按 allowedContentTypes 自动补扩展名，
        // 避免出现 "...mark.mp4-<时间戳>.mp4" 这类重复扩展名。
        let baseName: String
        switch exportMode {
        case .srt:
            baseName = "\(title)-\(rateStr)-srt"
        case .audio:
            baseName = "\(title)-\(voiceCore)-\(voiceTag)-\(rateStr)-\(pauseStr)-\(bgmTag)-wav"
        case .m4b:
            baseName = "\(title)-\(voiceCore)-\(voiceTag)-\(rateStr)-\(pauseStr)-\(bgmTag)-m4b-aac"
        case .video:
            baseName = "\(title)-\(voiceCore)-\(voiceTag)-\(rateStr)-\(pauseStr)-\(bgmTag)-\(themeTag)-\(aspectTag)-\(resTag)-\(codecTag)-\(fpsTag)-\(markTag)"
        }
        switch exportMode {
        case .srt:
            panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .data]
        case .audio:
            panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
        case .m4b:
            panel.allowedContentTypes = [UTType(filenameExtension: "m4b") ?? .audio]
        case .video:
            panel.allowedContentTypes = [.mpeg4Movie]
        }
        panel.nameFieldStringValue = sanitizeFilename("\(baseName)-\(stamp)")
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            log("已取消保存面板")
            return
        }

        isProcessing = true
        progress = 0
        progressText = "准备中..."
        previewURL = nil
        errorMessage = nil
        exportStartTime = Date()
        lastLoggedPercent = -1
        cancelFlag.withLock { $0 = false }
        let cancelled: @Sendable () -> Bool = { [lock = cancelFlag] in
            lock.withLock { $0 }
        }

        log("开始导出 · 模式=\(exportMode.rawValue) · 输出=\(url.path)")
        let resSuffix = exportMode == .video
            ? " · 分辨率=\(videoResolution.label) · 帧率=\(frameRate)fps"
            : ""
        let bgmLabel: String
        switch bgmPreset {
        case .none: bgmLabel = "关闭"
        case .gentlePiano: bgmLabel = "舒缓和弦 (\(Int(bgmVolume * 100))%)"
        case .oceanWaves: bgmLabel = "海浪波涛 (\(Int(bgmVolume * 100))%)"
        case .rainAmbience: bgmLabel = "沉浸雨声 (\(Int(bgmVolume * 100))%)"
        case .fireplace: bgmLabel = "温暖壁炉 (\(Int(bgmVolume * 100))%)"
        case .mountainStream: bgmLabel = "山间小溪 (\(Int(bgmVolume * 100))%)"
        case .forestWind: bgmLabel = "林间微风 (\(Int(bgmVolume * 100))%)"
        case .darkNoise: bgmLabel = "暗噪音 (\(Int(bgmVolume * 100))%)"
        case .pinkNoise: bgmLabel = "平衡粉噪 (\(Int(bgmVolume * 100))%)"
        case .custom: bgmLabel = "\(bgmURL?.lastPathComponent ?? "未选") (\(Int(bgmVolume * 100))%)"
        }
        log("  参数: 声音=\(voiceCore)\(voiceTag) · 语速=\(String(format: "%.2f", speechRate)) · 高亮色=\(highlightColorDescription)\(resSuffix) · BGM=\(bgmLabel) · 复用音频=\(useExistingAudio ? (companionAudioURL?.lastPathComponent ?? "未选") : "否")")

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(input: input, outputBase: url, cancelled: cancelled)
        }
    }

    private var highlightColorDescription: String {
        let c = highlightColor
        return String(format: "#%02X%02X%02X", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
    }

    /// 把「待保存文件名」清理为合法文件名：替换 `/ : \ ? * " < > | # %` 等
    /// 在文件系统/保存面板里不安全或易歧义的字符为 `-`，折叠连续 `-`，去首尾空白与点。
    private func sanitizeFilename(_ raw: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?*\"<>|#%\t\r\n")
        let cleaned = raw.components(separatedBy: forbidden).joined(separator: " - ")
        // 折叠连续分隔与空格
        let parts = cleaned.split(whereSeparator: { $0 == "-" || $0 == " " })
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        return parts.trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    /// 从可能带有生成参数的旧文件名中提取纯净主标题（避免重复叠加参数）
    private func cleanSourceTitle(_ raw: String) -> String {
        if let range = raw.range(of: "-\\[(Kokoro|Edge|API|AI|sys)\\]", options: .regularExpression) {
            let prefix = String(raw[..<range.lowerBound])
            if let lastDash = prefix.lastIndex(of: "-") {
                let core = String(prefix[..<lastDash])
                if !core.isEmpty { return core }
            }
            return prefix.isEmpty ? raw : prefix
        }
        return raw
    }

    /// 尝试在字幕文件同目录下寻找匹配的同名音频文件（.wav, .m4a, .mp3, .aac, .flac, .aiff）
    private static func findCompanionAudio(for subtitleURL: URL) -> URL? {
        let dir = subtitleURL.deletingLastPathComponent()
        let base = subtitleURL.deletingPathExtension().lastPathComponent
        let candidateExtensions = ["wav", "m4a", "mp3", "aac", "flac", "aiff"]
        let fm = FileManager.default

        for ext in candidateExtensions {
            let candidate = dir.appendingPathComponent(base).appendingPathExtension(ext)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// 获取当前生效的背景音乐文件（若是内置预设，则即时合成对应时长的环绕音轨）。
    private func resolveBGM(duration: Double) throws -> (url: URL, label: String, isTemp: Bool)? {
        switch bgmPreset {
        case .none:
            return nil
        case .custom:
            guard let url = bgmURL else { return nil }
            return (url, url.lastPathComponent, false)
        case .gentlePiano:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_piano_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "piano", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "舒缓和弦氛围乐", true)
        case .oceanWaves:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_ocean_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "ocean", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "海浪波涛", true)
        case .rainAmbience:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_rain_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "rain", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "沉浸雨声", true)
        case .fireplace:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_fireplace_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "fireplace", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "温暖壁炉", true)
        case .mountainStream:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_stream_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "stream", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "山间小溪", true)
        case .forestWind:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_forest_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "forest", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "林间微风", true)
        case .darkNoise:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_darknoise_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "darkNoise", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "暗噪音", true)
        case .pinkNoise:
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("bgm_pinknoise_\(UUID().uuidString).wav")
            try AudioEngine.generateProceduralBGM(preset: "pinkNoise", totalSeconds: duration + 10, outputURL: temp)
            return (temp, "平衡粉噪", true)
        }
    }

    func cancelExport() {
        cancelFlag.withLock { $0 = true }
        pipelineTask?.cancel()
        log("正在取消...")
    }

    private func runPipeline(
        input: InputKind,
        outputBase: URL,
        cancelled: @escaping @Sendable () -> Bool
    ) async {
        let engine = AudioEngine()
        let base = outputBase.deletingPathExtension()
        let wavURL = base.appendingPathExtension("wav")
        let srtURL = base.appendingPathExtension("srt")
        let assURL = base.appendingPathExtension("ass")
        let mp4URL = base.appendingPathExtension("mp4")
        let t0 = Date()
        var filesToCleanOnFailure: [URL] = []
        defer {
            if isProcessing == false && errorMessage != nil {
                for f in filesToCleanOnFailure { try? FileManager.default.removeItem(at: f) }
            }
        }

        do {
            switch (input, exportMode) {
            case (.book(_, let rawSentences), let mode):
                var sentences = rawSentences
                if translationSettings.enabled {
                    let toTrCount = sentences.filter { ($0.translation?.isEmpty ?? true) && TextProcessor.isPrimarilyEnglish($0.text) }.count
                    if toTrCount > 0 {
                        log("正在执行中英双语智能文学翻译（\(translationSettings.provider.displayName)，待翻译 \(toTrCount) 句）...")
                        let trStart = Date()
                        sentences = try await Translator.translateBook(
                            sentences: sentences,
                            settings: translationSettings,
                            onProgress: { [weak self] done, total in
                                Task { @MainActor [weak self] in
                                    self?.updateProgress(Double(done) / Double(max(total, 1)), text: "双语翻译 \(done)/\(total) 句")
                                }
                            },
                            onStatus: { [weak self] status in
                                Task { @MainActor [weak self] in
                                    self?.log(status)
                                }
                            },
                            cancellation: cancelled
                        )
                        log("中英双语翻译完成（共 \(sentences.count) 句，耗时 \(String(format: "%.1f", Date().timeIntervalSince(trStart)))s）")
                    }
                }

                let chapterRanges = TextProcessor.detectChaptersFromSentences(sentences: sentences)
                if exportByChapter && chapterRanges.count > 1 {
                    log("已检测到 \(chapterRanges.count) 个章节，正在按章节分卷导出...")
                    var allCreated: [URL] = []
                    var totalOutputDur: Double = 0
                    for (chIdx, item) in chapterRanges.enumerated() {
                        if cancelled() { throw BookStreamError.cancelled }
                        let chNum = String(format: "%02d", chIdx + 1)
                        let chTitle = sanitizeFilename(item.chapter.title)
                        let chBase = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent) - [\(chNum)] \(chTitle)")
                        let chSentences = Array(sentences[item.range])
                        let tag = "第 \(chIdx + 1)/\(chapterRanges.count) 章"
                        let (dur, mainURL, created) = try await renderSentenceBatch(
                            sentences: chSentences,
                            base: chBase,
                            mode: mode,
                            engine: engine,
                            cancelled: cancelled,
                            label: tag
                        )
                        allCreated.append(contentsOf: created)
                        totalOutputDur += dur
                        if chIdx == 0 && mode == .video { previewURL = mainURL }
                    }
                    filesToCleanOnFailure = allCreated
                    progress = 1
                    progressText = "完成"
                    log("全部分卷导出完成: 共产出 \(chapterRanges.count) 卷（总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s）")
                } else {
                    let (totalDur, mainURL, created) = try await renderSentenceBatch(
                        sentences: sentences,
                        base: base,
                        mode: mode,
                        engine: engine,
                        cancelled: cancelled,
                        label: nil
                    )
                    filesToCleanOnFailure = created
                    previewURL = mainURL
                    progress = 1
                    progressText = "完成"
                    let createdNames = created.map(\.lastPathComponent).joined(separator: " + ")
                    log("完成: \(createdNames)")
                    let mediaLabel: String
                    switch mode {
                    case .video: mediaLabel = "视频"
                    case .m4b: mediaLabel = "M4B"
                    case .audio: mediaLabel = "音频"
                    case .srt: mediaLabel = "字幕"
                    }
                    log("  结果: \(sentences.count) 句 / \(mediaLabel) \(String(format: "%.2f", totalDur))s / \(fileSize(mainURL)) / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
                }

            case (.subtitles, .srt):
                throw BookStreamError.unsupportedFile("字幕输入已自带 SRT，无需 SRT 模式")

            case (.subtitles(_, let entries), .audio):
                log("开始字幕旁白 TTS 抓轨（按原时间轴放置）...")
                let ttsStart = Date()
                let result = try await engine.renderSubtitleAudio(
                    entries: entries,
                    outputURL: wavURL,
                    engine: selectedTTSEngine,
                    kokoroVoice: selectedTTSEngine == .kokoro ? selectedKokoroVoiceID : nil,
                    edgeVoice: selectedTTSEngine == .edgeTTS ? selectedEdgeVoiceID : nil,
                    customAPISettings: selectedTTSEngine == .customAPI ? customAPISettings : nil,
                    rate: speechRate,
                    overflowPolicy: subtitleOverflowPolicy,
                    enableVocalWarmth: enableVocalWarmth,
                    progress: { [weak self] done, total in
                        self?.updateProgress(Double(done) / Double(max(total, 1)), text: "旁白抓轨 \(done)/\(total) 条")
                    },
                    cancellation: cancelled
                )
                for warning in result.warnings { log("⚠︎ " + warning) }
                logPhaseCompletion(phase: "音频", elapsed: Date().timeIntervalSince(ttsStart), mediaDuration: result.segments.last?.end ?? 0)
                try SrtWriter.write(segments: result.segments, to: srtURL)
                try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
                filesToCleanOnFailure = [wavURL, srtURL, assURL]
                previewURL = wavURL
                progress = 1
                progressText = "完成"
                log("完成: \(wavURL.lastPathComponent) + \(srtURL.lastPathComponent) + \(assURL.lastPathComponent)")
                log("  结果: \(result.segments.count) 条 / 音频 \(String(format: "%.2f", result.segments.last?.end ?? 0))s / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

            case (.subtitles(_, let entries), .m4b):
                log("开始字幕旁白 TTS 抓轨并封装 M4B 有声书...")
                let ttsStart = Date()
                let result = try await engine.renderSubtitleAudio(
                    entries: entries,
                    outputURL: wavURL,
                    engine: selectedTTSEngine,
                    kokoroVoice: selectedTTSEngine == .kokoro ? selectedKokoroVoiceID : nil,
                    edgeVoice: selectedTTSEngine == .edgeTTS ? selectedEdgeVoiceID : nil,
                    customAPISettings: selectedTTSEngine == .customAPI ? customAPISettings : nil,
                    rate: speechRate,
                    overflowPolicy: subtitleOverflowPolicy,
                    enableVocalWarmth: enableVocalWarmth,
                    progress: { [weak self] done, total in
                        self?.updateProgress(Double(done) / Double(max(total, 1)), text: "旁白抓轨 \(done)/\(total) 条")
                    },
                    cancellation: cancelled
                )
                for warning in result.warnings { log("⚠︎ " + warning) }
                logPhaseCompletion(phase: "音频", elapsed: Date().timeIntervalSince(ttsStart), mediaDuration: result.segments.last?.end ?? 0)
                try SrtWriter.write(segments: result.segments, to: srtURL)
                try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
                let m4bURL = base.appendingPathExtension("m4b")
                try AudioEngine.convertWavToM4b(wavURL: wavURL, outputURL: m4bURL)
                filesToCleanOnFailure = [wavURL, srtURL, assURL, m4bURL]
                previewURL = m4bURL
                progress = 1
                progressText = "完成"
                log("完成: \(m4bURL.lastPathComponent) + \(srtURL.lastPathComponent) + \(assURL.lastPathComponent)")
                log("  结果: \(result.segments.count) 条 / M4B \(fileSize(m4bURL)) / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

            case (.subtitles(_, let entries), .video):
                // 解耦：若用户已提供「已有音频 + 字幕」，直接复用其时间轴渲染，完全跳过 TTS
                if useExistingAudio, let companion = companionAudioURL {
                    log("复用已有音频 \(companion.lastPathComponent)，跳过 TTS（视频与音频+SRT 输出互不依赖）...")
                    let segments = entries.map {
                        TimedSegment(
                            id: $0.id,
                            text: $0.text,
                            translation: $0.translation,
                            startFrame: Int64(($0.start * AudioFormat.sampleRate).rounded()),
                            endFrame: Int64(($0.end * AudioFormat.sampleRate).rounded())
                        )
                    }
                    let totalDur = entries.last?.end ?? 0
                    log("视频渲染（\(frameRate)fps \(videoResolution.label)，主题=\(backgroundTheme.label)）...")
                    let renderStart = Date()
                    phaseStartTime = Date()
                    lastLoggedPercent = -1
                    let renderer = VideoRenderer()
                    filesToCleanOnFailure = [mp4URL]
                    try await renderer.render(
                        audioURL: companion,
                        segments: segments,
                        outputURL: mp4URL,
                        style: CaptionStyle(
                            highlight: highlightColor,
                            theme: backgroundTheme,
                            visualizerStyle: visualizerStyle,
                            font: subtitleFont,
                            enableKaraoke: enableKaraoke,
                            enableIntroOutro: enableIntroOutro,
                            enableParticles: enableParticles
                        ),
                        resolution: videoResolution,
                        codec: videoCodec,
                        watermark: watermark,
                        fps: frameRate,
                        progress: { [weak self] p in
                            self?.updateProgress(p, text: "视频渲染 \(Int(p * 100))%")
                        },
                        cancellation: cancelled
                    )
                    logPhaseCompletion(phase: "视频渲染", elapsed: Date().timeIntervalSince(renderStart), mediaDuration: totalDur)
                } else {
                    log("开始字幕旁白 TTS 抓轨（按原时间轴放置，视频音频轨复用）...")
                    let ttsStart = Date()
                    phaseStartTime = Date()
                    lastLoggedPercent = -1
                    let result = try await engine.renderSubtitleAudio(
                        entries: entries,
                        outputURL: wavURL,
                        engine: selectedTTSEngine,
                        kokoroVoice: selectedTTSEngine == .kokoro ? selectedKokoroVoiceID : nil,
                        edgeVoice: selectedTTSEngine == .edgeTTS ? selectedEdgeVoiceID : nil,
                        customAPISettings: selectedTTSEngine == .customAPI ? customAPISettings : nil,
                        rate: speechRate,
                        overflowPolicy: subtitleOverflowPolicy,
                        enableVocalWarmth: enableVocalWarmth,
                        progress: { [weak self] done, total in
                            self?.updateProgress(Double(done) / Double(max(total, 1)), text: "旁白抓轨 \(done)/\(total) 条")
                        },
                        cancellation: cancelled
                    )
                    for warning in result.warnings { self.log("⚠︎ " + warning) }
                    let totalDur = result.segments.last?.end ?? 0
                    logPhaseCompletion(phase: "音频", elapsed: Date().timeIntervalSince(ttsStart), mediaDuration: totalDur)
                    try SrtWriter.write(segments: result.segments, to: srtURL)
                    try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
                    if let bgmInfo = try resolveBGM(duration: totalDur) {
                        log("正在混入背景音乐（\(bgmInfo.label)，音量=\(Int(bgmVolume * 100))%，侧链压限=\(enableDucking ? "开" : "关")）...")
                        try AudioEngine.mixBGM(voiceWAVURL: wavURL, bgmURL: bgmInfo.url, outputURL: wavURL, bgmVolume: bgmVolume, enableDucking: enableDucking)
                        if bgmInfo.isTemp { try? FileManager.default.removeItem(at: bgmInfo.url) }
                    }
                    log("视频渲染（\(frameRate)fps \(videoResolution.label)，主题=\(backgroundTheme.label)）...")
                    let renderStart = Date()
                    phaseStartTime = Date()
                    lastLoggedPercent = -1
                    let renderer = VideoRenderer()
                    filesToCleanOnFailure = [wavURL, srtURL, assURL, mp4URL]
                    try await renderer.render(
                        audioURL: wavURL,
                        segments: result.segments,
                        outputURL: mp4URL,
                        style: CaptionStyle(
                            highlight: highlightColor,
                            theme: backgroundTheme,
                            visualizerStyle: visualizerStyle,
                            font: subtitleFont,
                            enableKaraoke: enableKaraoke,
                            enableIntroOutro: enableIntroOutro,
                            enableParticles: enableParticles
                        ),
                        resolution: videoResolution,
                        codec: videoCodec,
                        watermark: watermark,
                        fps: frameRate,
                        progress: { [weak self] p in
                            self?.updateProgress(p, text: "视频渲染 \(Int(p * 100))%")
                        },
                        cancellation: cancelled
                    )
                    logPhaseCompletion(phase: "视频渲染", elapsed: Date().timeIntervalSince(renderStart), mediaDuration: totalDur)
                }
                if autoGenerateCover {
                    let coverURL = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-cover.jpg")
                    let title = {
                        switch input {
                        case .book(let t, _): return t
                        case .subtitles(let t, _): return t
                        }
                    }()
                    try? VideoSynthesizer.generateCoverImage(
                        title: title,
                        chapter: nil,
                        theme: backgroundTheme,
                        aspectRatio: videoAspectRatio,
                        quality: videoQuality,
                        highlightColor: highlightColor,
                        outputURL: coverURL
                    )
                    log("  封面图: 自动生成高清短视频封面（已写出 \(coverURL.lastPathComponent)）")
                }
                previewURL = mp4URL
                progress = 1
                progressText = "完成"
                log("完成: \(mp4URL.lastPathComponent)")
                log("  结果: \(entries.count) 条 / MP4 \(fileSize(mp4URL)) / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            }
        } catch {
            let isCancelled = (error as? BookStreamError) == .cancelled || Task.isCancelled
            if isCancelled {
                log("任务已取消，已清理临时文件（耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s）")
                filesToCleanOnFailure = []
                try? FileManager.default.removeItem(at: mp4URL)
                try? FileManager.default.removeItem(at: wavURL)
                try? FileManager.default.removeItem(at: srtURL)
                try? FileManager.default.removeItem(at: assURL)
            } else {
                errorMessage = error.localizedDescription
                log("失败（耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s）: \(error.localizedDescription)")
            }
        }
        isProcessing = false
        cancelFlag.withLock { $0 = false }
    }

    /// 句子批次渲染辅助：支持全书渲染与按章节分卷独立渲染
    private func renderSentenceBatch(
        sentences: [Sentence],
        base: URL,
        mode: ExportMode,
        engine: AudioEngine,
        cancelled: @Sendable @escaping () -> Bool,
        label: String? = nil
    ) async throws -> (mediaDuration: Double, mainOutputURL: URL, allOutputs: [URL]) {
        let wavURL = base.appendingPathExtension("wav")
        let srtURL = base.appendingPathExtension("srt")
        let assURL = base.appendingPathExtension("ass")
        let mp4URL = base.appendingPathExtension("mp4")
        let prefix = label != nil ? "[\(label!)] " : ""

        if mode == .srt {
            let han = Self.hanRatio(of: sentences.prefix(200).map(\.text).joined())
            let cps = han > 0.2 ? 4.8 : 16.0
            let rateScale = Double(0.5 / max(speechRate, 0.1))
            var cursor = 0.0
            let estimated = sentences.map { s -> TimedSegment in
                let dur = Double(s.text.count) / cps * rateScale
                let seg = TimedSegment(id: s.id, text: s.text,
                                       startFrame: Int64((cursor * AudioFormat.sampleRate).rounded()),
                                       endFrame: Int64(((cursor + dur) * AudioFormat.sampleRate).rounded()))
                cursor += dur + s.pauseAfter
                return seg
            }
            try SrtWriter.write(segments: estimated, to: srtURL)
            try AssWriter.write(segments: estimated, highlight: highlightColor, to: assURL)
            let dur = estimated.last?.end ?? 0
            return (dur, srtURL, [srtURL, assURL])
        }

        log("\(prefix)开始 TTS 离线抓轨（\(sentences.count) 句）...")
        let ttsStart = Date()
        phaseStartTime = Date()
        lastLoggedPercent = -1
        let result = try await engine.renderBook(
            sentences: sentences,
            outputURL: wavURL,
            engine: selectedTTSEngine,
            kokoroVoice: selectedTTSEngine == .kokoro ? selectedKokoroVoiceID : nil,
            edgeVoice: selectedTTSEngine == .edgeTTS ? selectedEdgeVoiceID : nil,
            customAPISettings: selectedTTSEngine == .customAPI ? customAPISettings : nil,
            rate: speechRate,
            pauseScale: pauseScale,
            enableVocalWarmth: enableVocalWarmth,
            progress: { [weak self] done, total in
                self?.updateProgress(Double(done) / Double(max(total, 1)), text: "\(prefix)TTS 抓轨 \(done)/\(total) 句")
            },
            cancellation: cancelled
        )
        let totalDur = result.segments.last?.end ?? 0
        logPhaseCompletion(phase: "\(prefix)音频", elapsed: Date().timeIntervalSince(ttsStart), mediaDuration: totalDur)
        try SrtWriter.write(segments: result.segments, to: srtURL)
        try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
        let chapters = TextProcessor.detectChapters(segments: result.segments)
        let chURL = base.appendingPathExtension("chapters.txt")
        var outputs = [wavURL, srtURL, assURL]
        if !chapters.isEmpty {
            try ChapterWriter.write(chapters: chapters, to: chURL)
            outputs.append(chURL)
            log("  \(prefix)章节: 自动识别并导出 \(chapters.count) 个章节标记（已写出 \(chURL.lastPathComponent)）")
        }

        if let bgmInfo = try resolveBGM(duration: totalDur) {
            log("  \(prefix)正在混入背景音乐（\(bgmInfo.label)，音量=\(Int(bgmVolume * 100))%，侧链压限=\(enableDucking ? "开" : "关")）...")
            try AudioEngine.mixBGM(voiceWAVURL: wavURL, bgmURL: bgmInfo.url, outputURL: wavURL, bgmVolume: bgmVolume, enableDucking: enableDucking)
            if bgmInfo.isTemp { try? FileManager.default.removeItem(at: bgmInfo.url) }
        }

        if mode == .audio {
            return (totalDur, wavURL, outputs)
        }

        if mode == .m4b {
            let m4bURL = base.appendingPathExtension("m4b")
            log("  \(prefix)正在封装 M4B 高品质 AAC 有声书...")
            try AudioEngine.convertWavToM4b(wavURL: wavURL, outputURL: m4bURL)
            outputs.append(m4bURL)
            return (totalDur, m4bURL, outputs)
        }

        // 视频模式
        log("\(prefix)视频渲染（\(frameRate)fps \(videoResolution.label)，多核并发流水线，主题=\(backgroundTheme.label)）...")
        let renderStart = Date()
        phaseStartTime = Date()
        lastLoggedPercent = -1
        let renderer = VideoRenderer()
        try await renderer.render(
            audioURL: wavURL,
            segments: result.segments,
            outputURL: mp4URL,
            style: CaptionStyle(
                highlight: highlightColor,
                theme: backgroundTheme,
                visualizerStyle: visualizerStyle,
                font: subtitleFont,
                enableKaraoke: enableKaraoke,
                enableIntroOutro: enableIntroOutro,
                enableParticles: enableParticles
            ),
            resolution: videoResolution,
            codec: videoCodec,
            watermark: watermark,
            fps: frameRate,
            progress: { [weak self] p in
                self?.updateProgress(p, text: "\(prefix)视频渲染 \(Int(p * 100))%")
            },
            cancellation: cancelled
        )
        logPhaseCompletion(phase: "\(prefix)视频渲染", elapsed: Date().timeIntervalSince(renderStart), mediaDuration: totalDur)
        outputs.append(mp4URL)

        if autoGenerateCover {
            let coverURL = base.deletingLastPathComponent().appendingPathComponent("\(base.lastPathComponent)-cover.jpg")
            let bookTitle = {
                switch self.inputKind {
                case .book(let t, _): return t
                case .subtitles(let t, _): return t
                case nil: return "有声书"
                }
            }()
            try? VideoSynthesizer.generateCoverImage(
                title: bookTitle,
                chapter: label,
                theme: backgroundTheme,
                aspectRatio: videoAspectRatio,
                quality: videoQuality,
                highlightColor: highlightColor,
                outputURL: coverURL
            )
            outputs.append(coverURL)
            log("  \(prefix)封面图: 自动生成高清短视频封面（已写出 \(coverURL.lastPathComponent)）")
        }

        return (totalDur, mp4URL, outputs)
    }

    private func updateProgress(_ p: Double, text: String) {
        progress = p
        progressText = text
        // 每跨越 10% 边界记录一次：已用时间 + 按当前阶段实际速度推算的剩余时间
        // （0% 不记：阶段切换时的「0%」与阶段完成日志重复）
        let pct = Int(p * 100)
        let bucket = pct / 10 * 10
        if bucket != lastLoggedPercent, bucket >= 10 {
            lastLoggedPercent = bucket
            let elapsed = Date().timeIntervalSince(phaseStartTime)
            let remaining = p > 0.01 ? elapsed / p - elapsed : 0
            log("\(text) · 已用 \(Self.formatDuration(elapsed)) · 剩余约 \(Self.formatDuration(remaining))")
        }
    }

    /// 阶段完成日志：实际用时 + 产出时长 + 相对实时的速度倍数。
    private func logPhaseCompletion(phase: String, elapsed: TimeInterval, mediaDuration: Double) {
        let ratio = elapsed > 0 ? mediaDuration / elapsed : 0
        log("\(phase)完成: 用时 \(Self.formatDuration(elapsed)) · 产出 \(String(format: "%.1f", mediaDuration))s 内容 · 实时率 \(String(format: "%.1f", ratio))×")
    }

    private func fileSize(_ url: URL) -> String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int else { return "?" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

    /// 追加日志（带时间戳；上限 400 行）。DateFormatter 创建昂贵，用共享实例避免每行新建。
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    func log(_ message: String) {
        let line = "[\(Self.logTimeFormatter.string(from: Date()))] \(message)"
        logLines.append(line)
        if logLines.count > 400 { logLines.removeFirst(logLines.count - 400) }
    }

    /// 把解析期对原文的结构调整输出到日志：汇总统计 + 前若干条明细样例。
    func logTextFixes(_ fixes: [TextFix]) {
        guard !fixes.isEmpty else { return }
        let order: [TextFixKind] = [.stripBoilerplate, .skipTOC, .splitLong]
        let summary = order
            .compactMap { kind in
                let n = fixes.filter { $0.kind == kind }.count
                return n > 0 ? "\(kind.rawValue) \(n) 处" : nil
            }
            .joined(separator: " · ")
        log("文本结构处理: \(summary)（共 \(fixes.count) 处；仅影响断句，不修改原文标点）")
        for f in fixes.prefix(5) {
            let original = f.original.count > 24 ? f.original.prefix(24) + "…" : f.original
            let repaired = f.repaired.count > 24 ? f.repaired.prefix(24) + "…" : f.repaired
            log("  · 段落\(f.paraIndex) \(f.kind.rawValue): 「\(original)」→「\(repaired)」")
        }
        if fixes.count > 5 {
            log("  …其余 \(fixes.count - 5) 处省略（共 \(fixes.count) 处）")
        }
    }

    /// 复制全部日志到剪贴板（供粘贴给 AI 进行 debug）。
    func copyLog() {
        let text = logLines.joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        log("已复制全部日志（\(logLines.count) 行）到剪贴板")
    }

    private static func loadWatermark() -> WatermarkSettings {
        guard let data = UserDefaults.standard.data(forKey: "BookStream.watermark"),
              let wm = try? JSONDecoder().decode(WatermarkSettings.self, from: data) else {
            return .default
        }
        return wm
    }

    /// 更新水印并持久化。
    func updateWatermark(_ wm: WatermarkSettings) {
        watermark = wm
        if let data = try? JSONEncoder().encode(wm) {
            UserDefaults.standard.set(data, forKey: "BookStream.watermark")
        }
    }

    private static func loadTranslationSettings() -> TranslationSettings {
        guard let data = UserDefaults.standard.data(forKey: "BookStream.translationSettings"),
              let ts = try? JSONDecoder().decode(TranslationSettings.self, from: data) else {
            return .default
        }
        return ts
    }

    /// 更新翻译配置并持久化。
    func saveTranslationSettings() {
        if let data = try? JSONEncoder().encode(translationSettings) {
            UserDefaults.standard.set(data, forKey: "BookStream.translationSettings")
        }
    }

    private static func loadSelectedTTSEngine() -> TTSEngineType {
        if let raw = UserDefaults.standard.string(forKey: "BookStream.selectedTTSEngine"),
           let eng = TTSEngineType(rawValue: raw) {
            return eng
        }
        return .kokoro
    }

    private static func loadSelectedKokoroVoiceID() -> String {
        UserDefaults.standard.string(forKey: "BookStream.selectedKokoroVoiceID") ?? "af_heart"
    }

    private static func loadSelectedEdgeVoiceID() -> String {
        UserDefaults.standard.string(forKey: "BookStream.selectedEdgeVoiceID") ?? "zh-CN-YunxiNeural"
    }

    private static func loadHasUserPickedVoice() -> Bool {
        UserDefaults.standard.bool(forKey: "BookStream.hasUserPickedVoice")
    }

    private static func loadCustomAPISettings() -> CustomAPISettings {
        guard let data = UserDefaults.standard.data(forKey: "BookStream.customAPISettings"),
              let settings = try? JSONDecoder().decode(CustomAPISettings.self, from: data) else {
            return .default
        }
        return settings
    }

    /// 保存音色与语音引擎设置到 UserDefaults
    func saveVoiceSettings() {
        UserDefaults.standard.set(selectedTTSEngine.rawValue, forKey: "BookStream.selectedTTSEngine")
        UserDefaults.standard.set(selectedKokoroVoiceID, forKey: "BookStream.selectedKokoroVoiceID")
        UserDefaults.standard.set(selectedEdgeVoiceID, forKey: "BookStream.selectedEdgeVoiceID")
        UserDefaults.standard.set(hasUserPickedVoice, forKey: "BookStream.hasUserPickedVoice")
        if let data = try? JSONEncoder().encode(customAPISettings) {
            UserDefaults.standard.set(data, forKey: "BookStream.customAPISettings")
        }
    }

    /// 用户手动改过声音后持久化标记，不再被文件语言重置。
    func markVoicePickedByUser() {
        hasUserPickedVoice = true
        saveVoiceSettings()
    }

    /// 测试大模型翻译连接
    func testTranslation() {
        let settings = translationSettings
        log("正在测试翻译连接（\(settings.provider.displayName)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let sample = try await Translator.testConnection(settings: settings)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("✅ 翻译连接成功！译文样例: 「\(sample)」")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("❌ 翻译连接失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    /// 应用版本号（唯一代码侧出处）：优先取 Bundle（由 build.sh 打包写入），
    /// 无 Bundle（纯命令行模式）时回退默认。升级版本号改 build.sh 的 CFBundleShortVersionString 即可。
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.2.0"
    }()

    /// 环境信息（debug 辅助）。
    private static func environmentSummary() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · BookStream \(appVersion)"
    }
}

// MARK: - SwiftUI 界面

struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 420)
            rightPanel
                .frame(minWidth: 520)
        }
        .frame(minWidth: 980, minHeight: 620)
        .task { model.initializeApp() }
        .alert(
            "发生错误",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookStreamPickFile)) { _ in
            pickFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookStreamReloadFile)) { _ in
            if let url = model.inputURL {
                Task { await model.loadInput(url: url) }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookStreamStartExport)) { _ in
            if !model.isProcessing && model.inputKind != nil {
                model.startExport()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .bookStreamCancelExport)) { _ in
            if model.isProcessing {
                model.cancelExport()
            }
        }
    }

    // MARK: 左侧面板

    private var leftPanel: some View {
        ScrollView(.vertical, showsIndicators: true) {
            leftScrollContent
        }
        .padding(.top, 16)
    }

    /// 左栏可滚动内容（窗口高度不足时用进度条上下滚动定位下方被隐藏的控件）。
    private var leftScrollContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            topActionSection
            infoBox
            Toggle("智能拆分超长句（>60字/140词）", isOn: $model.splitLongSentences)
                .font(.caption)
                .onChange(of: model.splitLongSentences) { _ in
                    if let url = model.inputURL {
                        Task { await model.loadInput(url: url) }
                    }
                }
            Divider()
            unifiedVoiceSection
            rateSlider
            bilingualSection
            bgmSection
            Divider()
            modePicker
            if case .subtitles = model.inputKind {
                overflowPolicyPicker
            }
            colorPalette
            if model.exportMode == .video {
                themePicker
                fontPicker
                karaokeSection
                visualizerSection
                cinematicEffectsSection
                aspectRatioPicker
                qualityPicker
                codecPicker
                fpsPicker
                watermarkSection
                if case .subtitles = model.inputKind {
                    companionAudioSection
                }
            } else {
                vocalWarmthSection
            }
            if case .book = model.inputKind {
                chapterExportSection
            }
            HStack {
                Text(Self.versionString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
        }
        .padding([.leading, .trailing], 16)
        .padding(.bottom, 10)
    }

    /// 版本信息：如 v1.0.0(20260818_1146)。
    static var versionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "v\(AppModel.appVersion)(\(build))"
    }

    private var topActionSection: some View {
        HStack(spacing: 8) {
            // 紧凑型选择文件 / 拖放区域 (⌘I)
            Button {
                pickFile()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.inputKind == nil ? "doc.badge.plus" : "doc.text.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(model.inputKind == nil ? .secondary : Color.accentColor)
                    Text(model.inputKind == nil ? "选择或拖入文件 (⌘I)..." : (model.inputURL?.lastPathComponent ?? "已导入文件"))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        model.inputKind == nil ? Color.secondary.opacity(0.35) : Color.accentColor.opacity(0.6),
                        style: StrokeStyle(lineWidth: 1.5, dash: model.inputKind == nil ? [4] : [])
                    )
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(model.inputKind == nil ? 0.04 : 0.08)))
            )
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first else { return false }
                Task { await model.loadInput(url: url) }
                return true
            }

            // 开始生成 (⌘E) / 取消按钮 (⌘.) 紧靠导入框
            if model.isProcessing {
                Button(role: .destructive) {
                    model.cancelExport()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.fill")
                        Text("取消 (⌘.)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button {
                    model.startExport()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                        Text("开始生成 (⌘E)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 7)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .disabled(model.inputKind == nil)
            }
        }
    }

    private var infoBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("当前输入").font(.caption).foregroundStyle(.secondary)
            Text(model.summaryText).font(.callout)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }

    /// 全球多引擎 AI 语音选择系统
    private var unifiedVoiceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 语音引擎").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            Picker("引擎", selection: Binding(
                get: { model.selectedTTSEngine },
                set: { model.selectedTTSEngine = $0; model.saveVoiceSettings() }
            )) {
                ForEach(TTSEngineType.allCases) { eng in
                    Text(eng.label).tag(eng)
                }
            }
            .labelsHidden()

            switch model.selectedTTSEngine {
            case .kokoro:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Kokoro-82M 本地神经音色").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("试听") { model.previewKokoroVoice() }
                            .font(.caption)
                    }
                    Picker("音色", selection: Binding(
                        get: { model.selectedKokoroVoiceID },
                        set: { model.selectedKokoroVoiceID = $0; model.markVoicePickedByUser() }
                    )) {
                        ForEach(KokoroTTS.popularVoices) { v in
                            Text("\(v.displayName) [\(v.tag)]").tag(v.id)
                        }
                    }
                    .labelsHidden()
                    Text("💡 82M 本地顶级神经网络，0 网络依赖，媲美 ElevenLabs，无限时长稳定畅享")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            case .edgeTTS:
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("微软 Neural 广播音色").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("试听") { model.previewEdgeVoice() }
                            .font(.caption)
                    }
                    Picker("音色", selection: Binding(
                        get: { model.selectedEdgeVoiceID },
                        set: { model.selectedEdgeVoiceID = $0; model.markVoicePickedByUser() }
                    )) {
                        ForEach(EdgeTTS.popularVoices) { v in
                            Text("\(v.displayName) [\(v.tag)]").tag(v.id)
                        }
                    }
                    .labelsHidden()
                    Text("💡 48kHz 广播级原声录制，免 API Key，支持全网顶流有声书主播")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

            case .customAPI:
                customAPISection
            }
        }
    }

    private var customAPISection: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("服务商预设").font(.caption).foregroundStyle(.secondary)
                Picker("服务商", selection: Binding(
                    get: { model.customAPISettings.provider },
                    set: { newP in
                        model.customAPISettings.applyPreset(for: newP)
                        model.saveVoiceSettings()
                    }
                )) {
                    ForEach(CustomAPISettings.Provider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("API Key").font(.caption).foregroundStyle(.secondary)
                SecureField(model.customAPISettings.provider == .custom ? "可选 / sk-..." : "sk-...", text: Binding(
                    get: { model.customAPISettings.apiKey },
                    set: { model.customAPISettings.apiKey = $0; model.saveVoiceSettings() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("接口端点 URL").font(.caption).foregroundStyle(.secondary)
                TextField("https://api.openai.com/v1/audio/speech", text: Binding(
                    get: { model.customAPISettings.endpointURL },
                    set: { model.customAPISettings.endpointURL = $0; model.saveVoiceSettings() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("模型名称 (Model)").font(.caption).foregroundStyle(.secondary)
                TextField("tts-1-hd", text: Binding(
                    get: { model.customAPISettings.model },
                    set: { model.customAPISettings.model = $0; model.saveVoiceSettings() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("音色标识 (Voice ID)").font(.caption).foregroundStyle(.secondary)
                TextField("onyx", text: Binding(
                    get: { model.customAPISettings.voice },
                    set: { model.customAPISettings.voice = $0; model.markVoicePickedByUser() }
                ))
                .textFieldStyle(.roundedBorder)
                .font(.caption)
            }

            HStack {
                Text("💡 支持 OpenAI / 11Labs / 本地 GPU")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("测试并试听") { model.previewCustomAPIVoice() }
                    .font(.caption)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
    }

    /// 中英双语字幕控制面板
    private var bilingualSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("生成中英双语字幕（声音英文·双语显示）", isOn: Binding(
                get: { model.translationSettings.enabled },
                set: { model.translationSettings.enabled = $0; model.saveTranslationSettings() }
            ))
            .font(.caption.weight(.medium))

            if model.translationSettings.enabled {
                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("AI 翻译大模型").font(.caption).foregroundStyle(.secondary)
                        Picker("翻译引擎", selection: Binding(
                            get: { model.translationSettings.provider },
                            set: { newP in
                                model.translationSettings.provider = newP
                                model.translationSettings.endpointURL = newP.defaultEndpoint
                                model.translationSettings.model = newP.defaultModel
                                model.saveTranslationSettings()
                            }
                        )) {
                            ForEach(TranslationProvider.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .labelsHidden()
                    }

                    if model.translationSettings.provider != .builtInFree {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("接口 Base URL (自动适配各种格式)").font(.caption).foregroundStyle(.secondary)
                            TextField("https://api.deepseek.com 或 http://127.0.0.1:8000", text: Binding(
                                get: { model.translationSettings.endpointURL },
                                set: { model.translationSettings.endpointURL = $0; model.saveTranslationSettings() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.translationSettings.provider == .custom ? "API Key (本地 rapid-mlx 可留空)" : "API Key (sk-...)").font(.caption).foregroundStyle(.secondary)
                            SecureField(model.translationSettings.provider == .custom ? "可选 / 无需密钥可留空" : "sk-...", text: Binding(
                                get: { model.translationSettings.apiKey },
                                set: { model.translationSettings.apiKey = $0; model.saveTranslationSettings() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text("模型名称 (Model)").font(.caption).foregroundStyle(.secondary)
                            TextField("deepseek-chat / default", text: Binding(
                                get: { model.translationSettings.model },
                                set: { model.translationSettings.model = $0; model.saveTranslationSettings() }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }
                    }

                    HStack {
                        Text(model.translationSettings.provider == .custom ? "💡 完美支持本地 rapid-mlx / MLX 推理服务" : (model.translationSettings.provider == .deepseek ? "💡 DeepSeek 官方 API · 文学典雅" : "💡 免配置即开即用"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("测试连接") {
                            model.testTranslation()
                        }
                        .font(.caption)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
    }

    private var colorPalette: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("字幕高亮色").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                ForEach(AppModel.paletteColors, id: \.self) { c in
                    Circle()
                        .fill(Color(nsColor: c.nsColor))
                        .frame(width: 22, height: 22)
                        .overlay(
                            Circle().stroke(
                                model.highlightColor == c ? Color.primary : Color.clear,
                                lineWidth: 2.5
                            )
                        )
                        .contentShape(Circle())
                        .onTapGesture { model.highlightColor = c }
                }
            }
        }
    }

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("背景主题").font(.caption).foregroundStyle(.secondary)
            Picker("背景主题", selection: $model.backgroundTheme) {
                ForEach(BackgroundTheme.allCases) { t in
                    Text(t.label).tag(t)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var visualizerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("动态声波挂件").font(.caption).foregroundStyle(.secondary)
            Picker("声波样式", selection: $model.visualizerStyle) {
                ForEach(VisualizerStyle.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var cinematicEffectsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("片头封面与片尾渐隐 (1.5s)", isOn: $model.enableIntroOutro)
                .font(.caption)
            Toggle("深空微光呼吸与星尘背景", isOn: $model.enableParticles)
                .font(.caption)
            Toggle("自动生成高清短视频封面 (.jpg)", isOn: $model.autoGenerateCover)
                .font(.caption)
            Toggle("电台级录音棚人声温暖美化", isOn: $model.enableVocalWarmth)
                .font(.caption)
        }
    }

    private var vocalWarmthSection: some View {
        Toggle("电台级录音棚人声温暖美化", isOn: $model.enableVocalWarmth)
            .font(.caption)
    }

    private var chapterExportSection: some View {
        Toggle("按章节分卷导出（检测到多章时拆分）", isOn: $model.exportByChapter)
            .font(.caption)
    }

    /// 水印某字段的可写绑定：改动即整体更新并持久化。
    private func wmBinding<Value>(_ keyPath: WritableKeyPath<WatermarkSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.watermark[keyPath: keyPath] },
            set: { newValue in
                var wm = model.watermark
                wm[keyPath: keyPath] = newValue
                model.updateWatermark(wm)
            }
        )
    }

    /// 水印（文本/图片，位置/大小/透明度可调）。
    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("水印", isOn: wmBinding(\.enabled))
                .font(.caption)

            if model.watermark.enabled {
                // --- 1. 文字水印子面板 ---
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("文字水印", isOn: wmBinding(\.enableText))
                        .font(.caption)

                    if model.watermark.enableText {
                        HStack {
                            TextField("水印文本", text: wmBinding(\.text))
                                .textFieldStyle(.roundedBorder)
                                .font(.caption)
                        }

                        HStack(spacing: 8) {
                            Text("颜色").font(.caption).foregroundStyle(.secondary)
                            ForEach(AppModel.paletteColors, id: \.self) { c in
                                Circle()
                                    .fill(Color(nsColor: c.nsColor))
                                    .frame(width: 14, height: 14)
                                    .overlay(Circle().stroke(model.watermark.color == c ? Color.primary : Color.clear, lineWidth: 2))
                                    .contentShape(Circle())
                                    .onTapGesture { wmBinding(\.color).wrappedValue = c }
                            }
                        }

                        HStack {
                            Text("字号: \(Int(model.watermark.fontSize)) pt")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .leading)
                            Slider(value: wmBinding(\.fontSize), in: 14...72, step: 1)
                        }

                        HStack {
                            Text("透明度: \(Int(round(model.watermark.opacity * 100)))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 82, alignment: .leading)
                            Slider(value: wmBinding(\.opacity), in: 0.05...1.0, step: 0.01)
                        }

                        HStack {
                            Text("形态").font(.caption).foregroundStyle(.secondary)
                            Picker("形态", selection: wmBinding(\.motion)) {
                                ForEach(WatermarkSettings.Motion.allCases) { m in
                                    Text(m.label).tag(m)
                                }
                            }
                            .labelsHidden()
                        }

                        if model.watermark.motion == .static {
                            HStack {
                                Text("位置").font(.caption).foregroundStyle(.secondary)
                                Picker("位置", selection: wmBinding(\.position)) {
                                    ForEach(WatermarkSettings.Position.allCases) { p in
                                        Text(p.label).tag(p)
                                    }
                                }
                                .labelsHidden()
                            }
                        } else if model.watermark.motion == .bouncingDrift {
                            Text("💡 打砖块 2D 慢速平滑反弹游走，强力克制固定打码与搬运")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else if model.watermark.motion == .periodicFlythrough {
                            Text("💡 每 22 秒优雅横掠滑过一次（淡入→飘移→淡出），不遮挡常驻阅读")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)

                // --- 2. 图片 Logo 水印子面板 ---
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("图片 Logo 水印", isOn: wmBinding(\.enableImage))
                        .font(.caption)

                    if model.watermark.enableImage {
                        if model.watermark.imageData == nil {
                            Button("导入 Logo 图片文件 (PNG/JPEG)...") { importWatermarkImage() }
                                .font(.caption)
                        } else {
                            HStack {
                                Text("已导入 Logo 图片").font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Button("更换") { importWatermarkImage() }
                                    .font(.caption)
                                Button("清除") { wmBinding(\.imageData).wrappedValue = nil }
                                    .font(.caption)
                            }

                            HStack {
                                Text("缩放: \(Int(round(model.watermark.imageScale * 100)))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)
                                Slider(value: wmBinding(\.imageScale), in: 0.05...0.40, step: 0.01)
                            }

                            HStack {
                                Text("透明度: \(Int(round(model.watermark.imageOpacity * 100)))%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 82, alignment: .leading)
                                Slider(value: wmBinding(\.imageOpacity), in: 0.05...1.0, step: 0.01)
                            }

                            HStack {
                                Text("形态").font(.caption).foregroundStyle(.secondary)
                                Picker("形态", selection: wmBinding(\.imageMotion)) {
                                    ForEach(WatermarkSettings.Motion.allCases) { m in
                                        Text(m.label).tag(m)
                                    }
                                }
                                .labelsHidden()
                            }

                            if model.watermark.imageMotion == .static {
                                HStack {
                                    Text("位置").font(.caption).foregroundStyle(.secondary)
                                    Picker("位置", selection: wmBinding(\.imagePosition)) {
                                        ForEach(WatermarkSettings.Position.allCases) { p in
                                            Text(p.label).tag(p)
                                        }
                                    }
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                }
                .padding(6)
                .background(Color.primary.opacity(0.04))
                .cornerRadius(6)
            }
        }
    }

    private func importWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            var wm = model.watermark
            wm.imageData = data
            wm.enableImage = true
            model.updateWatermark(wm)
            model.log("已导入水印图片: \(url.lastPathComponent)")
        } catch {
            model.log("导入水印图片失败: \(error.localizedDescription)")
        }
    }

    /// 自定义字幕字体选择。
    private var fontPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("字幕字体").font(.caption).foregroundStyle(.secondary)
            Picker("字体", selection: $model.subtitleFont) {
                ForEach(SubtitleFont.allCases) { f in
                    Text(f.label).tag(f)
                }
            }
            .labelsHidden()
        }
    }

    /// 画幅比例选择（16:9 横屏 / 9:16 竖屏 / 1:1 方形）。
    private var aspectRatioPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("画幅比例").font(.caption).foregroundStyle(.secondary)
            Picker("比例", selection: $model.videoAspectRatio) {
                ForEach(VideoAspectRatio.allCases) { a in
                    Text(a.label).tag(a)
                }
            }
            .labelsHidden()
        }
    }

    /// 视频输出画质选择（480p/720p/1080p/4K）。
    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("画质分辨率").font(.caption).foregroundStyle(.secondary)
            Picker("画质", selection: $model.videoQuality) {
                ForEach(VideoQuality.allCases) { q in
                    Text(q.label).tag(q)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// 视频编码格式选择（H.264 / HEVC）。
    private var codecPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("视频编码").font(.caption).foregroundStyle(.secondary)
            Picker("编码", selection: $model.videoCodec) {
                ForEach(VideoCodec.allCases) { c in
                    Text(c.label).tag(c)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// 帧率选择（24/25/30/60）。
    private var fpsPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("帧率").font(.caption).foregroundStyle(.secondary)
            Picker("帧率", selection: $model.frameRate) {
                ForEach([24, 25, 30, 60], id: \.self) { f in
                    Text("\(f) fps").tag(f)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// 旁白溢出策略：语音长于字幕窗口时「顺延」保证语音完整同步，或「截断」保持原节奏。
    private var overflowPolicyPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("旁白超出窗口").font(.caption).foregroundStyle(.secondary)
            Picker("溢出策略", selection: $model.subtitleOverflowPolicy) {
                ForEach(SubtitleOverflowPolicy.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    /// 字幕 + 已有音频：跳过 TTS，直接按字幕时间轴渲染视频（与音频+SRT 输出解耦）。
    private var companionAudioSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("使用已有音频（跳过 TTS）", isOn: $model.useExistingAudio)
                .font(.caption)
            if model.useExistingAudio {
                HStack {
                    Text(model.companionAudioURL?.lastPathComponent ?? "未选择音频文件")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择...") { pickCompanionAudio() }
                        .font(.caption)
                }
                Text("支持 wav / m4a / mp3；直接复用音频轨与字幕时间轴，无需重新合成")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func pickCompanionAudio() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mpeg4Audio, .mp3]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.companionAudioURL = url
            model.log("已选择已有音频: \(url.lastPathComponent)")
        }
    }

    private var rateSlider: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("语速").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.2f", model.speechRate)).font(.caption.monospacedDigit())
            }
            Slider(value: $model.speechRate, in: 0.2...0.6, step: 0.05)
            // 停顿感只对「书」输入生效（renderBook 按句插入停顿；字幕模式由时间轴决定，无此参数）
            if case .book = model.inputKind {
                HStack {
                    Text("停顿感").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.1f×", model.pauseScale)).font(.caption.monospacedDigit())
                }
                Slider(value: $model.pauseScale, in: 0...2, step: 0.1)
            }
        }
    }

    /// 字级卡拉OK动态点亮动效（朗读时实时变色高亮）
    private var karaokeSection: some View {
        Toggle("字级卡拉OK点亮动效", isOn: $model.enableKaraoke)
            .font(.caption)
    }

    /// 背景音乐（BGM）混音与智能侧链避让压限配置。
    private var bgmSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("背景音乐 (BGM)").font(.caption).foregroundStyle(.secondary)
            Picker("背景音乐", selection: $model.bgmPreset) {
                ForEach(AppModel.BGMPreset.allCases) { p in
                    Text(p.rawValue).tag(p)
                }
            }
            .labelsHidden()

            if model.bgmPreset != .none {
                if model.bgmPreset == .custom {
                    HStack {
                        Text(model.bgmURL?.lastPathComponent ?? "未选择音乐文件")
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("选择音乐...") { pickBGM() }
                            .font(.caption)
                    }
                }
                HStack {
                    Text("BGM 音量").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        model.bgmVolume = max(0.0, Float(round(Double(model.bgmVolume - 0.01) * 100) / 100))
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)

                    Text(String(format: "%d%%", Int(round(model.bgmVolume * 100))))
                        .font(.caption.monospacedDigit().bold())
                        .frame(minWidth: 32, alignment: .trailing)

                    Button {
                        model.bgmVolume = min(1.0, Float(round(Double(model.bgmVolume + 0.01) * 100) / 100))
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
                Slider(value: $model.bgmVolume, in: 0.0...0.50, step: 0.01)

                // 常用微弱/背景音量档位快捷切换
                HStack(spacing: 5) {
                    ForEach([("1% 极微", Float(0.01)), ("3% 隐约", Float(0.03)), ("5% 轻柔", Float(0.05)), ("10% 背景", Float(0.10)), ("20% 明显", Float(0.20))], id: \.0) { label, vol in
                        Button {
                            model.bgmVolume = vol
                        } label: {
                            Text(label)
                                .font(.system(size: 10))
                                .padding(.horizontal, 3)
                                .padding(.vertical, 2)
                        }
                        .buttonStyle(.bordered)
                        .tint(abs(model.bgmVolume - vol) < 0.005 ? Color.accentColor : Color.secondary)
                    }
                }

                Toggle("智能侧链避让压限（朗读时自动降音）", isOn: $model.enableDucking)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if model.enableDucking {
                    Text("朗读时音量 \(String(format: "%.1f", Double(model.bgmVolume * 55)))% · 停顿空白时 \(Int(round(model.bgmVolume * 100)))%")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func pickBGM() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .wav, .mpeg4Audio, .mp3]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.bgmURL = url
            model.log("已选择背景音乐: \(url.lastPathComponent)")
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("导出模式").font(.caption).foregroundStyle(.secondary)
            Picker("模式", selection: $model.exportMode) {
                // 字幕输入已自带 SRT，SRT 模式无意义 → 仅书输入显示
                let modes: [AppModel.ExportMode] = {
                    if case .book = model.inputKind { return AppModel.ExportMode.allCases }
                    return [.audio, .video]
                }()
                ForEach(modes) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .plainText,
            .epub,
            UTType(filenameExtension: "srt") ?? .text,
            UTType(filenameExtension: "ass") ?? .text,
            UTType(filenameExtension: "ssa") ?? .text,
        ]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task { await model.loadInput(url: url) }
        }
    }

    // MARK: 右侧面板

    private var rightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            progressSection
            Divider()
            logSection
            Divider()
            previewSection
        }
        .padding(16)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("进度").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(model.progressText).font(.caption.monospacedDigit())
            }
            ProgressView(value: model.progress)
                .tint(.blue)
        }
        .disabled(!model.isProcessing && model.progress == 0)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("终端日志").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.copyLog()
                } label: {
                    Label("复制全部", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .disabled(model.logLines.isEmpty)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.logLines.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.black)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(6)
                }
                .background(Color.white) // 白背景黑字
                .cornerRadius(8)
                .frame(minHeight: 140, maxHeight: 200)
                .onChange(of: model.logLines.count) { _ in
                    withAnimation(.none) {
                        proxy.scrollTo(model.logLines.count - 1, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("回放预览").font(.caption).foregroundStyle(.secondary)
            if let url = model.previewURL {
                PlayerView(url: url)
                    .frame(maxHeight: .infinity)
                    .background(Color.black)
                    .cornerRadius(8)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "video")
                        .font(.system(size: 34))
                        .foregroundStyle(.tertiary)
                    Text("视频导出完成后在此预览")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
            }
        }
    }
}

// MARK: - AVPlayer 内嵌预览（AppKit 桥接）

struct PlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        let player = AVPlayer(url: url)
        view.player = player
        player.play()   // 首次出现（导出完成后预览URL从 nil 变为视频）即自动播放
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // 按 URL 比较（AVURLAsset 的 == 语义不可靠）；避免每次 SwiftUI 更新都重建播放器。
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            let newPlayer = AVPlayer(url: url)
            nsView.player = newPlayer
            newPlayer.play()   // 导出完成后预览：加载新视频即自动播放
        }
    }
}


