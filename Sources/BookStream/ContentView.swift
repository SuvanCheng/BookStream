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

    /// Piper 音质档（用于下载音色模型）。注意：并非每个音色都有所有档位。
    enum PiperQuality: String, CaseIterable, Identifiable {
        case low = "low"
        case medium = "medium"
        case high = "high"
        var id: String { rawValue }
        var label: String { "\(rawValue.uppercased())" }
    }

    struct VoiceInfo: Identifiable, Sendable {
        let id: String
        let name: String
        let language: String
        let qualityRank: Int  // 3=Premium 2=增强 1=默认

        var qualityLabel: String {
            switch qualityRank {
            case 3: return "Premium"
            case 2: return "增强"
            default: return "默认"
            }
        }
    }

    /// 系统自带的新颖/卡通音色（不能作为有声书，载入时直接从列表剔除）。
    private static let noveltyVoiceNames: Set<String> = [
        "Albert", "Bad News", "Bahh", "Bells", "Boing", "Bubbles", "Cellos",
        "Deranged", "Eddy", "Flo", "Fred", "Good News", "Grandma", "Grandpa",
        "Jester", "Junior", "Organ", "Ralph", "Reed", "Rocko", "Sandy", "Shelley",
        "Superstar", "Trinoids", "Whisper", "Wobble", "Zarvox",
    ]

    /// 公认更接近人声的自然音色（自动选择时优先）。
    private static let preferredNaturalVoices: Set<String> = [
        "Samantha", "Victoria", "Alex", "Karen", "Daniel", "Tingting", "Meijia",
    ]

    /// 高亮色调色盘
    static let paletteColors: [CaptionColor] = [
        .vividOrange, .red, .yellow, .green, .cyan, .blue, .purple, .pink, .white,
    ]

    // 输入
    @Published var inputKind: InputKind?
    @Published var inputURL: URL?

    // 设置
    @Published var voices: [VoiceInfo] = []
    @Published var selectedVoiceID: String?
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

    // 本地 AI 音色（Piper）
    @Published var piperModels: [PiperVoice] = []
    @Published var selectedPiperVoiceID: String?   // 选中 AI 音色：可指向已安装模型 id，或目录条目 id（未下载，生成时自动下载）；nil = 使用系统声音
    @Published var piperEngineInstalled = false
    @Published var isPiperInstalling = false
    @Published var isModelDownloading = false
    @Published var piperQuality: PiperQuality = .medium
    @Published var piperCatalog: [PiperCatalogEntry] = []
    @Published var catalogLoadFailed = false
    // 首次刷新时是否已确立 AI 音色默认（只自动选一次，不覆盖用户后续手工选择）
    private var piperDefaultChosen = false

    // 已有音频复用（字幕输入 + 视频模式时，可跳过 TTS）
    @Published var useExistingAudio = false
    @Published var companionAudioURL: URL?
    @Published var smartParse = true   // 智能解析：自动修复原文标点（补漏/改错/折叠重复），可关闭
    @Published var splitLongSentences = true   // L3：超长句（>60 字）按软边界拆短

    // 字幕旁白溢出策略（语音长于字幕窗口时：顺延 / 截断）
    @Published var subtitleOverflowPolicy: SubtitleOverflowPolicy = .extend

    // 水印（视频导出用，UserDefaults 持久化）
    @Published var watermark: WatermarkSettings = AppModel.loadWatermark()

    // 运行状态
    @Published var isProcessing = false
    @Published var progress: Double = 0
    @Published var progressText = ""
    @Published var logLines: [String] = []
    @Published var previewURL: URL?
    @Published var errorMessage: String?

    private var pipelineTask: Task<Void, Never>?
    private let cancelFlag = OSAllocatedUnfairLock(initialState: false)
    private var hasUserPickedVoice = false
    private var previewSynthesizer: AVSpeechSynthesizer?
    private var previewAudioPlayer: AVAudioPlayer?
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
            return "\(title) · \(entries.count) 条 · 总时长 \(Self.formatDuration(dur))"
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
    /// 语速缩放与 Piper 的 length-scale 一致：1 + (0.5 - rate) * 1.2。
    private static func estimateAudioDuration(chars: Int, hanRatio: Double, rate: Float) -> Double {
        guard chars > 0 else { return 0 }
        let base = hanRatio > 0.2 ? 4.8 : 17.0
        let rateScale = 1.0 + Double(0.5 - rate) * 1.2
        return Double(chars) / base * rateScale
    }

    /// 预估生成耗时（秒）：TTS 合成 + 视频渲染。
    /// 基准（实测校准）：Piper 本地引擎约 600 字/秒；视频渲染约 20× 实时（480p），
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

    func loadVoices() {
        let all = AVSpeechSynthesisVoice.speechVoices()
        voices = all.compactMap { v -> VoiceInfo? in
            // 剔除系统特效/新颖音色：不能作为有声书，直接从列表移除
            guard !Self.noveltyVoiceNames.contains(v.name) else { return nil }
            let rank: Int
            if #available(macOS 14.0, *) {
                rank = v.quality == .premium ? 3 : (v.quality == .enhanced ? 2 : 1)
            } else {
                rank = v.quality == .enhanced ? 2 : 1
            }
            return VoiceInfo(
                id: v.identifier,
                name: v.name,
                language: v.language,
                qualityRank: rank
            )
        }
        .sorted { a, b in
            if a.qualityRank != b.qualityRank { return a.qualityRank > b.qualityRank }
            if a.language != b.language { return a.language < b.language }
            return a.name < b.name
        }
        if selectedVoiceID == nil {
            selectDefaultVoice(for: nil)
        }
        // “默认”应指向实际选中的音色（selectedVoiceID），而非排序表首
        let selected = voices.first { $0.id == selectedVoiceID }
        let (name, lang) = selected.flatMap { ($0.name, $0.language) } ?? ("", "")
        log("环境: \(Self.environmentSummary())")
        log("已加载 \(voices.count) 个系统声音（Premium/增强优先，默认 \(name) [\(lang)]）")
    }

    /// 按内容语言自动选择最佳自然音色（质量优先、优先公认自然音色）。
    func selectDefaultVoice(for text: String?) {
        let language = Self.detectLanguage(of: text)
        func matchesLanguage(_ v: VoiceInfo) -> Bool {
            v.language == language || v.language.hasPrefix(language)
        }
        let best = voices.first { v in
            Self.preferredNaturalVoices.contains(v.name) && matchesLanguage(v)
        } ?? voices.first { v in
            matchesLanguage(v)
        } ?? voices.first
        guard let best else { return }
        if selectedVoiceID != best.id {
            selectedVoiceID = best.id
            log("检测内容语言为 \(Self.languageName(language))，自动选择声音: \(best.name)（可手动更换）")
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

    /// 试听所选声音（简短样例，实时合成）。
    func previewVoice() {
        guard let id = selectedVoiceID, let voice = AVSpeechSynthesisVoice(identifier: id) else { return }
        let utterance = AVSpeechUtterance(string: "Hello, this is a preview of the selected voice. 你好，这是所选声音的试听。")
        utterance.voice = voice
        utterance.rate = 0.45
        // 延迟创建：避免在应用启动时就初始化语音框架（与后台抓轨并存）
        let synth = previewSynthesizer ?? {
            let s = AVSpeechSynthesizer()
            previewSynthesizer = s
            return s
        }()
        synth.stopSpeaking(at: .immediate)
        synth.speak(utterance)
        log("试听声音: \(voice.name)")
    }

    /// 用户手动改过声音后，不再按内容语言自动切换。
    func markVoicePickedByUser() {
        hasUserPickedVoice = true
    }

    /// 试听当前选中的 AI 音色（本地合成一句样例并播放）。
    func previewPiperVoice() {
        guard piperEngineInstalled, let voice = selectedPiperVoice else { return }
        let rate = speechRate
        log("正在合成 AI 试听（\(voice.displayName) · \(voice.language)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let buffers = try PiperTTS().render(
                    text: "This is a preview of the local AI voice. 你好，这是本地 AI 音色的试听。",
                    voice: voice, rate: rate
                )
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("piper-preview-\(UUID().uuidString).wav")
                let sr = buffers.first?.format.sampleRate ?? 16000
                let file = try AVAudioFile(forWriting: tmp, settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: sr,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ], commonFormat: .pcmFormatFloat32, interleaved: false)
                for buf in buffers { try file.write(from: buf) }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.previewAudioPlayer = try? AVAudioPlayer(contentsOf: tmp)
                        self.previewAudioPlayer?.play()
                        self.log("AI 音色试听播放中（\(voice.displayName)）")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
                            try? FileManager.default.removeItem(at: tmp)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.log("AI 音色试听失败: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - 本地 AI 音色（Piper）

    /// 刷新 AI 引擎状态与已安装音色模型。
    func refreshPiper(forceCatalog: Bool = false) {
        PiperTTS.invalidateEngineCache()   // 安装/下载后引擎探测结果可能已变
        piperEngineInstalled = PiperTTS.engineStatus() != .notInstalled
        piperModels = PiperTTS.listModels()
        // 需求：默认音色 = AI 音色里可用的第一个；只有首次刷新、且用户未手工选过时才自动确立，
        // 之后不再覆盖用户选择（选了“使用系统声音”也保留）。
        if !piperDefaultChosen {
            if let first = piperModels.first, selectedPiperVoiceID == nil {
                selectedPiperVoiceID = first.id
                log("默认使用 AI 音色: \(first.displayName) · \(first.language)")
            }
            piperDefaultChosen = true
        }
        if let selected = selectedPiperVoiceID {
            // 仅当该 id 既不是已安装模型、也不是目录条目时，才视为失效清空；
            // 允许“仅选中未下载目录音色”（保留，生成时自动下载）。
            let installed = piperModels.contains { $0.id == selected }
            let catalogOK = piperCatalog.contains { $0.id == selected }
            if !installed && !catalogOK {
                selectedPiperVoiceID = nil
            }
        }
        if piperEngineInstalled {
            log("AI 引擎就绪（\(piperModels.count) 个本地音色模型）")
        }
        // 后台拉取可下载音色目录（联网）。仅在“尚未载入 / 上次失败 / 用户点刷新”时联网，
        // 避免每次下载完成或常规刷新都重新抓一遍 voices.json。
        let needCatalog = forceCatalog || piperCatalog.isEmpty || catalogLoadFailed
        guard needCatalog else { return }
        Task.detached(priority: .utility) {
            do {
                let catalog = try PiperTTS.fetchCatalog()
                await MainActor.run {
                    self.piperCatalog = catalog
                    self.catalogLoadFailed = false
                }
            } catch {
                await MainActor.run { self.catalogLoadFailed = true }
            }
        }
    }

    /// 一次性安装本地 AI 引擎（pip 安装 piper-tts，需联网；之后完全离线）。
    /// 注意：必须在后台线程执行（pip3 安装可能耗时数分钟，不能阻塞主线程）。
    func installPiperEngine() {
        guard !isPiperInstalling else { return }
        isPiperInstalling = true
        log("正在安装本地 AI 引擎（pip3 install piper-tts，一次性）...")
        Task.detached(priority: .userInitiated) {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/pip3")
            proc.arguments = ["install", "--user", "piper-tts"]
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            let status: Int32
            do {
                try proc.run()
                proc.waitUntilExit()
                status = proc.terminationStatus
            } catch {
                status = -1
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.isPiperInstalling = false
                    if status == 0 {
                        self.log("AI 引擎安装完成")
                        self.refreshPiper()
                    } else {
                        self.log("AI 引擎安装失败（退出码 \(status)，请手动执行: pip3 install --user piper-tts）")
                    }
                }
            }
        }
    }

    /// 下载指定目录条目（按 id），并**等待到完成/失败**后返回结果。
    /// 返回下载后的 PiperVoice；失败时抛出。用于「选中未下载音色 → 生成前自动下载」。
    func downloadCatalogEntryAndWait(_ id: String) async throws -> PiperVoice {
        guard !isModelDownloading else {
            throw BookStreamError.audioRenderFailed("已有音色在下载中，请稍后再试")
        }
        guard let entry = piperCatalog.first(where: { $0.id == id }) else {
            throw BookStreamError.audioRenderFailed("该音色不在可下载目录中: \(id)")
        }
        isModelDownloading = true
        let quality = piperQuality.rawValue
        log("生成前自动下载 AI 音色 \(entry.displayName)（档位 \(quality)）...")
        do {
            let voice = try await Task.detached(priority: .userInitiated) {
                try PiperTTS.downloadCanonical(catalogEntry: entry, quality: quality)
            }.value
            self.isModelDownloading = false
            self.refreshPiper()
            self.log("AI 音色下载完成: \(voice.displayName) · \(voice.language)（\(voice.id)）")
            return voice
        } catch {
            self.isModelDownloading = false
            self.log("AI 音色下载失败: \(error.localizedDescription)")
            throw error
        }
    }

    /// 删除已下载的音色模型（.onnx/.onnx.json 一并移除），并清理选中状态。
    func deletePiperVoice(_ voice: PiperVoice) {
        guard piperModels.contains(where: { $0.id == voice.id }) else { return }
        PiperTTS.deleteModel(voice)
        if selectedPiperVoiceID == voice.id { selectedPiperVoiceID = nil }
        refreshPiper()
        log("已删除 AI 音色: \(voice.displayName) · \(voice.language)")
    }

    /// 手动下载「选中的未下载目录音色」（不阻塞，后台跑完回调刷新列表）。
    func startSelectedVoiceDownload() {
        guard let id = selectedPiperVoiceID,
              let entry = piperCatalog.first(where: { $0.id == id }),
              selectedPiperVoice == nil else { return }
        guard !isModelDownloading else {
            log("已有音色在下载中，请稍后再试")
            return
        }
        isModelDownloading = true
        let quality = piperQuality.rawValue
        log("正在下载 AI 音色 \(entry.displayName)（档位 \(quality)，约 20~60MB）...")
        Task.detached(priority: .userInitiated) {
            do {
                let voice = try PiperTTS.downloadCanonical(catalogEntry: entry, quality: quality)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.isModelDownloading = false
                        self.refreshPiper()
                        self.log("AI 音色下载完成: \(voice.displayName) · \(voice.language)（\(voice.id)）")
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self.isModelDownloading = false
                        self.log("AI 音色下载失败: \(error.localizedDescription)")
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
                let repair = smartParse
                let splitLong = splitLongSentences
                let (sentences, fixes) = try await Task.detached(priority: .userInitiated) {
                    try TextProcessor.parseBookFile(url: url, repair: repair, splitLong: splitLong)
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
                log("SRT 解析完成: \(entries.count) 条（\(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
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
        let title = {
            switch input {
            case .book(let t, _): return t
            case .subtitles(let t, _): return t
            }
        }()
        let voiceCore: String
        let voiceTag: String
        if let aiName = selectedVoiceDisplayName {
            voiceCore = aiName
            voiceTag = "[AI]"
        } else {
            voiceCore = voices.first { $0.id == selectedVoiceID }?.name ?? "系统默认"
            voiceTag = "[sys]"
        }
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

    /// 当前选中的 AI 音色（nil = 使用系统声音）。若选中的是“目录条目但尚未下载”，返回 nil。
    var selectedPiperVoice: PiperVoice? {
        guard let id = selectedPiperVoiceID else { return nil }
        // 直接命中已安装模型 id（en_US-lessac-medium）
        if let m = piperModels.first(where: { $0.id == id }) { return m }
        // 命中目录条目 id（en_US-lessac）→ 从已安装里按「语言-数据集」前缀找对应档位。
        // 同一数据集可能装了多个质量档，优先选与当前「质量档」一致的那个，避免挑到无关档位。
        if let e = piperCatalog.first(where: { $0.id == id }) {
            let prefix = "\(e.language)-\(e.dataset)-"
            if let q = piperModels.first(where: { $0.id == prefix + piperQuality.rawValue }) {
                return q
            }
            return piperModels.first { $0.id.hasPrefix(prefix) }
        }
        return nil
    }

    /// 选中的目录条目（若选中值指向目录里的一个词条）。
    var selectedCatalogEntry: PiperCatalogEntry? {
        guard let id = selectedPiperVoiceID else { return nil }
        return piperCatalog.first { $0.id == id }
    }

    /// 选中音色的“已显示名称”（渲染用 voiceCore；未下载时也用目录名）。
    var selectedVoiceDisplayName: String? {
        if let v = selectedPiperVoice { return v.displayName }
        return selectedCatalogEntry?.displayName
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
            // 若选中了「尚未下载」的 AI 音色，生成前先自动下载好，再进入渲染。
            if let id = selectedPiperVoiceID, selectedPiperVoice == nil {
                log("所选 AI 音色尚未下载，先生成前自动下载...")
                _ = try await downloadCatalogEntryAndWait(id)
                if cancelled() { return }
            }
            switch (input, exportMode) {
            case (.book(_, let sentences), let mode):
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
                    voiceIdentifier: selectedVoiceID,
                    piperVoice: selectedPiperVoice,
                    rate: speechRate,
                    overflowPolicy: subtitleOverflowPolicy,
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
                    voiceIdentifier: selectedVoiceID,
                    piperVoice: selectedPiperVoice,
                    rate: speechRate,
                    overflowPolicy: subtitleOverflowPolicy,
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
                            startFrame: Int64(($0.start * AudioFormat.sampleRate).rounded()),
                            endFrame: Int64(($0.end * AudioFormat.sampleRate).rounded())
                        )
                    }
                    let totalDur = entries.last?.end ?? 0
                    log("视频渲染（\(frameRate)fps \(videoResolution.label)，主题=\(backgroundTheme.label)）...")
                    let renderStart = Date()
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
                    let result = try await engine.renderSubtitleAudio(
                        entries: entries,
                        outputURL: wavURL,
                        voiceIdentifier: selectedVoiceID,
                        piperVoice: selectedPiperVoice,
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
            voiceIdentifier: selectedVoiceID,
            piperVoice: selectedPiperVoice,
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

    /// 把解析期对原文的标点修复输出到日志：汇总统计 + 前若干条明细样例。
    func logTextFixes(_ fixes: [TextFix]) {
        guard !fixes.isEmpty else { return }
        let order: [TextFixKind] = [.stripBoilerplate, .skipTOC, .addPeriod, .fixBoundary, .collapseDuplicate, .splitLong]
        let summary = order
            .compactMap { kind in
                let n = fixes.filter { $0.kind == kind }.count
                return n > 0 ? "\(kind.rawValue) \(n) 处" : nil
            }
            .joined(separator: " · ")
        log("已调整原文: \(summary)（共 \(fixes.count) 处；仅影响解析结果，不修改原文件）")
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

    /// 应用版本号（唯一代码侧出处）：优先取 Bundle（由 build.sh 打包写入），
    /// 无 Bundle（纯命令行模式）时回退默认。升级版本号改 build.sh 的 CFBundleShortVersionString 即可。
    static let appVersion: String = {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
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
    // 左侧控制区滚动状态（可滚动区 0...1 的进度 + 是否溢出需要滚动条）
    @State private var leftScrollFraction: Double = 0
    @State private var leftScrollHasOverflow: Bool = false
    @State private var showAIVoicePanel: Bool = false

    var body: some View {
        HSplitView {
            leftPanel
                .frame(minWidth: 340, idealWidth: 360, maxWidth: 420)
            rightPanel
                .frame(minWidth: 520)
        }
        .frame(minWidth: 980, minHeight: 620)
        .task { model.loadVoices() }
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
        VStack(spacing: 0) {
            LeftScrollHost(
                scrollFraction: $leftScrollFraction,
                hasOverflow: $leftScrollHasOverflow
            ) {
                leftScrollContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 底部滚动进度条：拖动可定位窗口高度被裁掉的左栏控件
            if leftScrollHasOverflow {
                leftScrollProgressBar
            }
        }
        .padding(.top, 16)
        .task { model.refreshPiper() }
    }

    /// 左栏可滚动内容（窗口高度不足时用进度条上下滚动定位下方被隐藏的控件）。
    private var leftScrollContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            topActionSection
            infoBox
            Toggle("智能解析（修复标点/合并折行）", isOn: $model.smartParse)
                .font(.caption)
            Toggle("拆分超长句（>60 字）", isOn: $model.splitLongSentences)
                .font(.caption)
                .onChange(of: model.smartParse) { _ in
                    // 开关变化后重新解析当前输入，保证日志/句数即时更新
                    if let url = model.inputURL {
                        Task { await model.loadInput(url: url) }
                    }
                }
                .onChange(of: model.splitLongSentences) { _ in
                    if let url = model.inputURL {
                        Task { await model.loadInput(url: url) }
                    }
                }
            Divider()
            voicePicker
            aiVoiceSection
            rateSlider
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

    private var leftScrollProgressBar: some View {
        ScrollProgressBar(
            fraction: Binding(
                get: { leftScrollFraction },
                set: { leftScrollFraction = min(max($0, 0), 1) }
            )
        )
        .frame(height: 24)
    }

    /// 本地 AI 音色（Piper）选择与安装。
    private var aiVoiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            // —— 入口头：点击展开/收起整个音色面板 ——
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showAIVoicePanel.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("AI 音色（本地 · 离线）")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(aiVoiceSummary)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: showAIVoicePanel ? "chevron.up" : "chevron.down")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)

                if model.selectedPiperVoice != nil && !showAIVoicePanel {
                    Button("试听") { model.previewPiperVoice() }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .disabled(model.isModelDownloading)
                }
            }

            if showAIVoicePanel {
                if model.piperEngineInstalled {
                    aiVoiceInstalledPanel
                } else {
                    // 引擎未安装：只给安装 + 刷新
                    HStack(spacing: 10) {
                        if model.isPiperInstalling {
                            Text("正在安装引擎...").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("安装本地 AI 引擎（一次性，约 150MB）") { model.installPiperEngine() }
                                .font(.caption)
                        }
                        Button("刷新") { model.refreshPiper(forceCatalog: true) }
                            .font(.caption)
                    }
                    Text("引擎为本地神经网络 TTS（piper-tts），安装后合成完全离线")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// 入口头摘要：当前所选 AI 音色（或“未下载/使用系统声音”）。
    private var aiVoiceSummary: String {
        if let v = model.selectedPiperVoice { return "\(v.displayName) · \(v.language)" }
        if let e = model.selectedCatalogEntry { return "\(e.displayName) · 未下载" }
        return "使用系统声音"
    }

    /// 引擎已安装：统一音色列表 + 选中音色的操作条。
    private var aiVoiceInstalledPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 统一音色列表（已安装打勾；目录未安装标“未下载”）
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    aiVoiceRow(
                        label: "使用系统声音",
                        installed: true,
                        selected: model.selectedPiperVoiceID == nil
                    ) {
                        model.selectedPiperVoiceID = nil
                        model.log("切换为系统声音")
                        withAnimation(.easeInOut(duration: 0.2)) { showAIVoicePanel = false }
                    } trailing: {
                        EmptyView()
                    }

                    ForEach(model.piperModels) { v in
                        aiVoiceRow(
                            label: "\(v.displayName) · \(v.language)",
                            installed: true,
                            selected: model.selectedPiperVoiceID == v.id
                        ) { [weak model] in
                            model?.selectedPiperVoiceID = v.id
                            model?.log("切换 AI 音色: \(v.displayName) · \(v.language)")
                            withAnimation(.easeInOut(duration: 0.2)) { showAIVoicePanel = false }
                        } trailing: {
                            Image(systemName: "checkmark")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    ForEach(model.piperCatalog) { e in
                        // 已安装的目录条目不重复列出
                        let installed = model.piperModels.contains { $0.id.hasPrefix("\(e.language)-\(e.dataset)-") }
                        if !installed {
                            aiVoiceRow(
                                label: "\(e.displayName) · \(e.language) · 未下载",
                                installed: false,
                                selected: model.selectedPiperVoiceID == e.id
                            ) { [weak model] in
                                model?.selectedPiperVoiceID = e.id
                                model?.log("已选未下载音色 \(e.displayName) · 生成时自动下载")
                                withAnimation(.easeInOut(duration: 0.2)) { showAIVoicePanel = false }
                            } trailing: {
                                Text("未下载")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 170)

            if model.piperCatalog.isEmpty && !model.catalogLoadFailed {
                Text("正在加载在线音色目录...").font(.caption2).foregroundStyle(.secondary)
            }
            if model.catalogLoadFailed {
                Text("在线目录加载失败（网络），点「刷新」重试").font(.caption2).foregroundStyle(.secondary)
            }

            // 选中音色的操作条：试听 / 删除（已装）；下载（未装）；未选提示
            HStack(spacing: 8) {
                if let v = model.selectedPiperVoice {
                    Button("试听") { model.previewPiperVoice() }
                        .font(.caption)
                        .disabled(model.isModelDownloading)
                    Button("删除") { model.deletePiperVoice(v) }
                        .font(.caption)
                        .disabled(model.isModelDownloading)
                } else if model.selectedPiperVoiceID != nil {
                    Button("下载") { model.startSelectedVoiceDownload() }
                        .font(.caption)
                        .disabled(model.isModelDownloading)
                    Text("选中未下载，生成时也会自动下载")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("未选择 AI 音色，将用系统声音")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if model.isModelDownloading {
                    Text("下载中...").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("刷新") { model.refreshPiper(forceCatalog: true) }
                    .font(.caption)
            }

            // 下载质量档位
            HStack(spacing: 8) {
                Text("质量档").font(.caption).foregroundStyle(.secondary)
                Picker("质量", selection: $model.piperQuality) {
                    ForEach(AppModel.PiperQuality.allCases) { q in
                        Text(q.label).tag(q)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 180)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 音色列表单行：高亮当前选中的；点击选中。
    private func aiVoiceRow(
        label: String,
        installed: Bool,
        selected: Bool,
        onSelect: @escaping () -> Void,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                trailing()
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
            .opacity(installed ? 1 : 0.75)
        }
        .buttonStyle(.plain)
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

    private var voicePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("系统声音").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("试听") { model.previewVoice() }
                    .font(.caption)
                    .disabled(model.selectedVoiceID == nil)
            }
            Picker("声音", selection: Binding(
                get: { model.selectedVoiceID },
                set: { model.selectedVoiceID = $0; model.markVoicePickedByUser() }
            )) {
                ForEach(model.voices) { v in
                    Text(voiceLabel(v)).tag(v.id as String?)
                }
            }
            .labelsHidden()
        }
    }

    private func voiceLabel(_ v: AppModel.VoiceInfo) -> String {
        var label = "\(v.name) (\(v.language))"
        if v.qualityRank > 1 {
            label += " · \(v.qualityLabel)"
        }
        return label
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

// MARK: - 左侧控制区可滚动容器
//
// 左栏内容较多，当全局窗口高度小于内容高度时，下方的控制按钮会被裁掉而无法访问。
// 这里用 NSScrollView 桥接：自带原生系统滚动条（滚轮/两指可滚），同时把滚动进度
// （0...1）暴露给 SwiftUI，配合左下角的可拖动进度条，可直观定位被隐藏的控件。

/// 跟随窗口宽度横向贴合、纵向可滚动的 NSScrollView。
@MainActor
private final class LeftFittingScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let doc = documentView else { return }
        let clipW = contentView.bounds.width
        var f = doc.frame
        f.size.width = clipW
        if f.size.height < contentView.bounds.height {
            f.size.height = contentView.bounds.height
        }
        doc.frame = f
    }
}

/// 左栏滚动容器的协调器：持有 NSScrollView + NSHostingController，负责把滚动进度
/// 双向同步到 SwiftUI（滚轮滚动→上报进度；拖动进度条→按进度滚动），并上报是否溢出。
@MainActor
private final class LeftScrollCoordinator: NSObject {
    let scrollView = LeftFittingScrollView()
    let controller = NSHostingController(rootView: AnyView(EmptyView()))
    /// 直接写回 SwiftUI 绑定（滚动进度 0...1 / 是否溢出）。
    var onFractionWriteBack: ((Double) -> Void)?
    var onOverflowWriteBack: ((Bool) -> Void)?
    /// 上次应用（由进度条驱动）的进度，用于抑制回环。
    var lastAppliedFraction: Double?
    var lastReportedFraction: Double?
    var lastReportedOverflow: Bool?

    override init() {
        super.init()
        let sv = scrollView
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.scrollerStyle = .overlay
        sv.drawsBackground = false
        sv.borderType = .noBorder
        sv.documentView = controller.view
        sv.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: sv.contentView
        )
    }

    @objc private func boundsDidChange(_ note: Notification) {
        if let doc = scrollView.documentView {
            var f = doc.frame
            f.size.width = scrollView.contentView.bounds.width
            doc.frame = f
        }
        refreshMetrics()
    }

    /// 计算当前滚动进度（0...1）与是否溢出，并回调给 SwiftUI。
    func refreshMetrics(force: Bool = false) {
        controller.view.layoutSubtreeIfNeeded()
        let clipH = scrollView.contentView.bounds.height
        let docH = controller.view.fittingSize.height
        // 显式把文档高度设为内容自然高度（≥ 可视区），保证内容超出时真正可滚动。
        if let doc = scrollView.documentView {
            var f = doc.frame
            f.size.width = scrollView.contentView.bounds.width
            f.size.height = max(docH, clipH)
            doc.frame = f
        }
        // 让 NSScrollView 按新文档尺寸重算滚动范围。
        scrollView.reflectScrolledClipView(scrollView.contentView)
        let maxScroll = max(docH - clipH, 0)
        let overflow = maxScroll > 1
        if overflow != lastReportedOverflow || force {
            lastReportedOverflow = overflow
            onOverflowWriteBack?(overflow)
        }
        let fr: Double = maxScroll > 0 ? Double(scrollView.contentView.bounds.origin.y / maxScroll) : 0
        let clamped = min(max(fr, 0), 1)
        if abs(clamped - (lastReportedFraction ?? -1)) > 0.0005 || force {
            lastReportedFraction = clamped
            onFractionWriteBack?(clamped)
        }
    }

    /// 把内容视图及其滚动文档刷新为给定 SwiftUI 内容。
    func setContent<Content: View>(_ content: Content) {
        controller.rootView = AnyView(content)
        controller.view.layoutSubtreeIfNeeded()
        if let doc = scrollView.documentView {
            var f = doc.frame
            f.size.width = scrollView.contentView.bounds.width
            doc.frame = f
        }
        refreshMetrics(force: true)
    }

    /// 按目标进度滚动（由底部进度条拖动触发）。
    func applyFraction(_ target: Double) {
        let clamped = min(max(target, 0), 1)
        // 若与当前实际进度一致则跳过，避免回环。
        refreshMetrics()
        if abs(clamped - (lastReportedFraction ?? -1)) < 0.0005 {
            lastAppliedFraction = clamped
            return
        }
        let clipH = scrollView.contentView.bounds.height
        let docH = controller.view.frame.height
        let maxScroll = max(docH - clipH, 0)
        lastAppliedFraction = clamped
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: clamped * maxScroll))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// 把左栏内容包进可滚动区域，并向 SwiftUI 暴露滚动进度（0...1）与是否溢出。
private struct LeftScrollHost<Content: View>: NSViewRepresentable {
    @Binding var scrollFraction: Double
    @Binding var hasOverflow: Bool
    let content: Content
    /// 绑定句柄（指向 @State 真实存储，供权威侧写回）。
    private let fractionBinding: Binding<Double>
    private let overflowBinding: Binding<Bool>

    init(
        scrollFraction: Binding<Double>,
        hasOverflow: Binding<Bool>,
        @ViewBuilder content: () -> Content
    ) {
        self._scrollFraction = scrollFraction
        self._hasOverflow = hasOverflow
        self.fractionBinding = scrollFraction
        self.overflowBinding = hasOverflow
        self.content = content()
    }

    func makeCoordinator() -> LeftScrollCoordinator { LeftScrollCoordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        // 滚动进度 / 溢出直接写回 @State 真实存储（主线程自动，无回环：同值不重复应用）。
        coordinator.onFractionWriteBack = { [fractionBinding] fr in
            fractionBinding.wrappedValue = fr
        }
        coordinator.onOverflowWriteBack = { [overflowBinding] ov in
            overflowBinding.wrappedValue = ov
        }
        // 内容更新（左栏全部控件 + 版本号）。
        coordinator.setContent(content)
        // 若底部进度条拖动改变了进度，则按目标滚动。
        let target = scrollFraction
        if abs(target - (coordinator.lastAppliedFraction ?? -1)) > 0.0005 {
            coordinator.applyFraction(target)
        }
    }
}

/// 左栏底部的滚动进度条：Thumb 反映当前滚动进度，拖动即把左栏滚到对应位置，
/// 用于定位窗口高度不足、被裁掉的隐藏控件。
private struct ScrollProgressBar: View {
    @Binding var fraction: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let thumb: CGFloat = 26
            let travel = max(width - thumb, 1)
            let x = CGFloat(fraction) * travel
            ZStack(alignment: .leading) {
                // 轨道
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 6)
                    .frame(maxHeight: .infinity)
                // Thumb
                Capsule()
                    .fill(Color.accentColor.opacity(0.75))
                    .frame(width: thumb, height: 6)
                    .offset(x: x)
            }
            .frame(height: 26, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let clamped = min(max((v.location.x - thumb / 2) / travel, 0), 1)
                        fraction = Double(clamped)
                    }
            )
        }
        .frame(height: 26)
        .padding(.horizontal, 16)
        .accessibilityLabel("左侧控制区滚动进度")
    }
}
