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
        case audioSRT = "离线音频 + SRT"
        case video = "动态字幕视频"
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
    @Published var speechRate: Float = 0.5
    @Published var pauseScale: Float = 1.0   // 句间/段间停顿倍数（0=无停顿，2=两倍）
    @Published var exportMode: ExportMode = .video
    @Published var highlightColor: CaptionColor = .vividOrange
    @Published var videoResolution: VideoResolution = .p1080
    @Published var scrollStrength: Double = 0.5   // 变速强度：句内滚动速度变化幅度 0...1

    // 本地 AI 音色（Piper）
    @Published var piperModels: [PiperVoice] = []
    @Published var selectedPiperVoiceID: String?   // nil = 使用系统声音
    @Published var piperEngineInstalled = false
    @Published var isPiperInstalling = false
    @Published var isModelDownloading = false
    @Published var piperQuality: PiperQuality = .medium
    @Published var piperCatalog: [PiperCatalogEntry] = []
    @Published var selectedCatalogEntryID: String?   // 目录中想下载的模型名
    @Published var catalogLoadFailed = false

    // 已有音频复用（字幕输入 + 视频模式时，可跳过 TTS）
    @Published var useExistingAudio = false
    @Published var companionAudioURL: URL?

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

    // MARK: - 派生信息

    var summaryText: String {
        guard let input = inputKind else { return "尚未载入文件" }
        switch input {
        case .book(let title, let sentences):
            let chars = sentences.reduce(0) { $0 + $1.text.count }
            let est = Double(chars) / 12.5
            return "\(title) · \(sentences.count) 句 · \(chars) 字 · 预估 \(formatDuration(est))"
        case .subtitles(let title, let entries):
            let dur = entries.last.map { $0.end } ?? 0
            return "\(title) · \(entries.count) 条 · 总时长 \(formatDuration(dur))"
        }
    }

    private func formatDuration(_ s: Double) -> String {
        let total = Int(s)
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
        log("正在合成 AI 试听（\(voice.displayName) · \(voice.language)）...")
        Task.detached(priority: .userInitiated) {
            do {
                let buffers = try PiperTTS().render(
                    text: "This is a preview of the local AI voice. 你好，这是本地 AI 音色的试听。",
                    voice: voice, rate: 0.5
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
        if let selected = selectedPiperVoiceID,
           !piperModels.contains(where: { $0.id == selected }) {
            selectedPiperVoiceID = nil
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
                    if let cur = self.selectedCatalogEntryID,
                       !catalog.contains(where: { $0.id == cur }) {
                        self.selectedCatalogEntryID = catalog.first?.id
                    }
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

    /// 一次性下载指定音色模型（rhasspy/piper-voices；之后完全离线）。
    func downloadPiperModel(language: String, dataset: String) {
        guard !isModelDownloading else { return }
        isModelDownloading = true
        let quality = piperQuality.rawValue
        log("正在下载 AI 音色 \(language)-\(dataset)-\(quality)（约 20~60MB，一次性；若该档位不存在会自动回退到更低档）...")
        // 优先用目录规范路径（含语言族前缀），目录未加载时才回退到按语言-数据集拼的旧路径。
        let catalogEntry = piperCatalog.first { $0.id == "\(language)-\(dataset)" }
        Task.detached(priority: .userInitiated) {
            do {
                let voice: PiperVoice
                if let entry = catalogEntry {
                    voice = try PiperTTS.downloadCanonical(catalogEntry: entry, quality: quality)
                } else {
                    voice = try PiperTTS.downloadModel(language: language, dataset: dataset, quality: quality)
                }
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

    /// 从目录下载当前选中的音色模型（语言-数据集 + 当前质量档，含自动回退档位）。
    func downloadCatalogEntry() {
        guard let id = selectedCatalogEntryID,
              let entry = piperCatalog.first(where: { $0.id == id }) else {
            log("请先在目录里选择一个音色模型")
            return
        }
        guard !isModelDownloading else { return }
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

    /// 目录选中项的描述：显示该音色实际可用的质量档位。
    var catalogSelectionDescription: String {
        guard let id = selectedCatalogEntryID,
              let entry = piperCatalog.first(where: { $0.id == id }) else { return "未选择" }
        let qs = entry.availableQualities.isEmpty ? "档位未知" : entry.availableQualities.joined(separator: "/")
        let already = piperModels.contains { $0.id.hasPrefix("\(entry.language)-\(entry.dataset)-") }
        return "\(entry.displayName) · 档位 \(qs)\(already ? " · ✓已下载" : "")"
    }

    func loadInput(url: URL) async {
        let t0 = Date()
        log("解析输入: \(url.lastPathComponent)（\(url.path)）")
        errorMessage = nil
        do {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "txt", "epub":
                let sentences = try await Task.detached(priority: .userInitiated) {
                    try TextProcessor.parseBookFile(url: url)
                }.value
                inputKind = .book(
                    title: url.deletingPathExtension().lastPathComponent,
                    sentences: sentences
                )
                let chars = sentences.reduce(0) { $0 + $1.text.count }
                log("书籍解析完成: \(sentences.count) 句 / \(chars) 字（\(String(format: "%.2f", Date().timeIntervalSince(t0)))s）")
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
        switch exportMode {
        case .audioSRT:
            panel.allowedContentTypes = [UTType(filenameExtension: "wav") ?? .audio]
            panel.nameFieldStringValue = "BookStream-\(stamp).wav"
        case .video:
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "BookStream-\(stamp).mp4"
        }
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
        cancelFlag.withLock { $0 = false }
        let cancelled: @Sendable () -> Bool = { [lock = cancelFlag] in
            lock.withLock { $0 }
        }

        let voiceName: String
        if let ai = selectedPiperVoice {
            voiceName = "\(ai.displayName) [AI]"
        } else {
            voiceName = voices.first { $0.id == selectedVoiceID }?.name ?? "系统默认"
        }
        log("开始导出 · 模式=\(exportMode.rawValue) · 输出=\(url.path)")
        let resSuffix = exportMode == .video ? " · 分辨率=\(videoResolution.label)" : ""
        log("  参数: 声音=\(voiceName) · 语速=\(String(format: "%.2f", speechRate)) · 高亮色=\(highlightColorDescription)\(resSuffix) · 复用音频=\(useExistingAudio ? (companionAudioURL?.lastPathComponent ?? "未选") : "否")")

        pipelineTask = Task { [weak self] in
            guard let self else { return }
            await self.runPipeline(input: input, outputBase: url, cancelled: cancelled)
        }
    }

    private var highlightColorDescription: String {
        let c = highlightColor
        return String(format: "#%02X%02X%02X", Int(c.red * 255), Int(c.green * 255), Int(c.blue * 255))
    }

    /// 当前选中的 AI 音色（nil = 使用系统声音）。
    private var selectedPiperVoice: PiperVoice? {
        guard let id = selectedPiperVoiceID else { return nil }
        return piperModels.first { $0.id == id }
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
            case (.book(_, let sentences), .audioSRT):
                log("开始 TTS 离线抓轨（\(sentences.count) 句）...")
                let result = try await engine.renderBook(
                    sentences: sentences,
                    outputURL: wavURL,
                    voiceIdentifier: selectedVoiceID,
                    piperVoice: selectedPiperVoice,
                    rate: speechRate,
                    pauseScale: pauseScale,
                    progress: { [weak self] done, total in
                        self?.updateProgress(Double(done) / Double(max(total, 1)), text: "TTS 抓轨 \(done)/\(total) 句")
                    },
                    cancellation: cancelled
                )
                try SrtWriter.write(segments: result.segments, to: srtURL)
                try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
                filesToCleanOnFailure = [wavURL, srtURL, assURL]
                previewURL = nil
                progress = 1
                progressText = "完成"
                let totalDur = result.segments.last?.end ?? 0
                log("完成: \(wavURL.lastPathComponent) + \(srtURL.lastPathComponent) + \(assURL.lastPathComponent)")
                log("  结果: \(result.segments.count) 句 / 音频 \(String(format: "%.2f", totalDur))s / WAV \(fileSize(wavURL)) / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

            case (.book(_, let sentences), .video):
                let tmpWAV = FileManager.default.temporaryDirectory
                    .appendingPathComponent("bookstream-\(UUID().uuidString).wav")
                defer { try? FileManager.default.removeItem(at: tmpWAV) }
                // 视频模式完全自包含：内部抓轨仅用于生成音频轨，不产出/依赖任何 .srt 文件
                log("内部 TTS 抓轨（视频模式自动生成音频轨，不涉及 SRT）...")
                let result = try await engine.renderBook(
                    sentences: sentences,
                    outputURL: tmpWAV,
                    voiceIdentifier: selectedVoiceID,
                    piperVoice: selectedPiperVoice,
                    rate: speechRate,
                    pauseScale: pauseScale,
                    progress: { [weak self] done, total in
                        self?.updateProgress(Double(done) / Double(max(total, 1)), text: "TTS 抓轨 \(done)/\(total) 句")
                    },
                    cancellation: cancelled
                )
                log("视频渲染（复用合成音频，30fps \(videoResolution.label)）...")
                let renderer = VideoRenderer()
                filesToCleanOnFailure = [mp4URL]
                try await renderer.render(
                    audioURL: tmpWAV,
                    segments: result.segments,
                    outputURL: mp4URL,
                    style: CaptionStyle(highlight: highlightColor, scrollStrength: scrollStrength),
                    resolution: videoResolution,
                    watermark: watermark,
                    progress: { [weak self] p in
                        self?.updateProgress(p, text: "视频渲染 \(Int(p * 100))%")
                    },
                    cancellation: cancelled
                )
                previewURL = mp4URL
                progress = 1
                progressText = "完成"
                let totalDur = result.segments.last?.end ?? 0
                log("完成: \(mp4URL.lastPathComponent)")
                log("  结果: \(result.segments.count) 句 / 视频 \(String(format: "%.2f", totalDur))s / MP4 \(fileSize(mp4URL)) / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

            case (.subtitles(_, let entries), .audioSRT):
                log("开始字幕旁白 TTS 抓轨（按原时间轴放置）...")
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
                try SrtWriter.write(segments: result.segments, to: srtURL)
                try AssWriter.write(segments: result.segments, highlight: highlightColor, to: assURL)
                filesToCleanOnFailure = [wavURL, srtURL, assURL]
                progress = 1
                progressText = "完成"
                log("完成: \(wavURL.lastPathComponent) + \(srtURL.lastPathComponent) + \(assURL.lastPathComponent)")
                log("  结果: \(result.segments.count) 条 / 音频 \(String(format: "%.2f", result.segments.last?.end ?? 0))s / 总耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")

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
                    let renderer = VideoRenderer()
                    filesToCleanOnFailure = [mp4URL]
                    try await renderer.render(
                        audioURL: companion,
                        segments: segments,
                        outputURL: mp4URL,
                        style: CaptionStyle(highlight: highlightColor, scrollStrength: scrollStrength),
                        resolution: videoResolution,
                        watermark: watermark,
                        progress: { [weak self] p in
                            self?.updateProgress(p, text: "视频渲染 \(Int(p * 100))%")
                        },
                        cancellation: cancelled
                    )
                } else {
                    let tmpWAV = FileManager.default.temporaryDirectory
                        .appendingPathComponent("bookstream-\(UUID().uuidString).wav")
                    defer { try? FileManager.default.removeItem(at: tmpWAV) }
                    log("内部 TTS 抓轨（视频模式自动生成音频轨，不涉及 SRT）...")
                    let result = try await engine.renderSubtitleAudio(
                        entries: entries,
                        outputURL: tmpWAV,
                        voiceIdentifier: selectedVoiceID,
                        piperVoice: selectedPiperVoice,
                        rate: speechRate,
                        overflowPolicy: subtitleOverflowPolicy,
                        progress: { [weak self] done, total in
                            self?.updateProgress(Double(done) / Double(max(total, 1)), text: "旁白抓轨 \(done)/\(total) 条")
                        },
                        cancellation: cancelled
                    )
                    for warning in result.warnings { self.log("⚠︎ " + warning) }
                    let renderer = VideoRenderer()
                    filesToCleanOnFailure = [mp4URL]
                    try await renderer.render(
                        audioURL: tmpWAV,
                        segments: result.segments,
                        outputURL: mp4URL,
                        style: CaptionStyle(highlight: highlightColor, scrollStrength: scrollStrength),
                        resolution: videoResolution,
                        watermark: watermark,
                        progress: { [weak self] p in
                            self?.updateProgress(p, text: "视频渲染 \(Int(p * 100))%")
                        },
                        cancellation: cancelled
                    )
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

    private func updateProgress(_ p: Double, text: String) {
        progress = p
        progressText = text
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
    }

    // MARK: 左侧面板

    private var leftPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            dropZone
            infoBox
            Divider()
            voicePicker
            aiVoiceSection
            rateSlider
            Divider()
            modePicker
            if case .subtitles = model.inputKind {
                overflowPolicyPicker
            }
            if model.exportMode == .video {
                colorPalette
                resolutionPicker
                watermarkSection
                if case .subtitles = model.inputKind {
                    companionAudioSection
                }
            }
            actionButtons
            Spacer(minLength: 0)
            // 左下角版本信息（辅助判断是否最新版），负偏移贴近真正的左下角
            HStack {
                Text(Self.versionString)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
            }
            .offset(x: -10, y: 15)
        }
        .padding(16)
        .task { model.refreshPiper() }
    }

    /// 本地 AI 音色（Piper）选择与安装。
    private var aiVoiceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("AI 音色（本地 · 离线）").font(.caption).foregroundStyle(.secondary)

            if model.piperEngineInstalled {
                HStack {
                    Picker("AI 音色", selection: Binding(
                        get: { model.selectedPiperVoiceID },
                        set: { newID in
                            model.selectedPiperVoiceID = newID
                            if let voice = model.piperModels.first(where: { $0.id == newID }) {
                                model.log("切换 AI 音色: \(voice.displayName) · \(voice.language)")
                            } else {
                                model.log("切换为系统声音")
                            }
                        }
                    )) {
                        Text("使用系统声音").tag(String?.none)
                        ForEach(model.piperModels) { v in
                            Text("\(v.displayName) · \(v.language)").tag(v.id as String?)
                        }
                    }
                    .labelsHidden()
                    Spacer()
                    Button("试听") { model.previewPiperVoice() }
                        .font(.caption)
                        .disabled(model.selectedPiperVoiceID == nil)
                }

                if model.piperModels.isEmpty {
                    Text("尚未下载音色模型，可下载中/英文各一个（约 20~125MB，一次性）")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    if model.isModelDownloading {
                        Text("下载中...").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Button("下载英文音色（LibriTTS-R 真人朗读）") { model.downloadPiperModel(language: "en_US", dataset: "libritts_r") }
                            .font(.caption)
                        Button("下载中文音色") { model.downloadPiperModel(language: "zh_CN", dataset: "huayan") }
                            .font(.caption)
                        Button("刷新") { model.refreshPiper(forceCatalog: true) }
                            .font(.caption)
                    }
                }
                .disabled(model.piperEngineInstalled == false)
                // 下载质量档位可选（并非每个音色都有所有档位；下载失败会自动回退到低档）
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
                .frame(maxWidth: .infinity, alignment: .leading)
                // 完整音色目录：按名称选择任一下载（来源 rhasspy/piper-voices）
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Text("更多音色（按名称选择下载）").font(.caption).foregroundStyle(.secondary)
                    if model.catalogLoadFailed {
                        Text("在线目录加载失败（网络）——可先用上方快捷按钮，稍后点「刷新」重试")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if model.piperCatalog.isEmpty {
                        Text("正在加载在线目录...").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        Picker("音色", selection: $model.selectedCatalogEntryID) {
                            ForEach(model.piperCatalog) { e in
                                Text(e.displayName).tag(e.id as String?)
                            }
                        }
                        .labelsHidden()
                        HStack(spacing: 8) {
                            Button("下载该音色") { model.downloadCatalogEntry() }
                                .font(.caption)
                            Text(model.catalogSelectionDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
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

    /// 版本信息：如 v1.0.0(20260818_1146)。
    static var versionString: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
        return "v\(AppModel.appVersion)(\(build))"
    }

    private var dropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "books.vertical")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("拖入 .txt / .epub / .srt / .ass / .ssa")
                .font(.headline)
            Text("或")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("选择文件...") { pickFile() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                .foregroundStyle(.tertiary)
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Task { await model.loadInput(url: url) }
            return true
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
            HStack {
                Text("变速强度").font(.caption).foregroundStyle(.secondary)
                Text("0（匀速）").font(.caption2).foregroundStyle(.tertiary)
                Slider(value: $model.scrollStrength, in: 0...1)
                Text("1（缓动）").font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// 水印（文本/图片，位置/大小/透明度可调）。
    private var watermarkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("水印", isOn: Binding(
                get: { model.watermark.enabled },
                set: { on in
                    var wm = model.watermark
                    wm.enabled = on
                    model.updateWatermark(wm)
                }
            ))
            .font(.caption)

            if model.watermark.enabled {
                Picker("类型", selection: Binding(
                    get: { model.watermark.imageData == nil ? 0 : 1 },
                    set: { kind in
                        var wm = model.watermark
                        if kind == 0 { wm.imageData = nil } else if wm.imageData == nil { wm.text = "" }
                        model.updateWatermark(wm)
                    }
                )) {
                    Text("文本").tag(0)
                    Text("图片").tag(1)
                }
                .labelsHidden()
                .pickerStyle(.segmented)

                if model.watermark.imageData == nil {
                    HStack {
                        TextField("水印文本", text: Binding(
                            get: { model.watermark.text },
                            set: { var wm = model.watermark; wm.text = $0; model.updateWatermark(wm) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        Button("导入图片") { importWatermarkImage() }
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
                                .onTapGesture {
                                    var wm = model.watermark
                                    wm.color = c
                                    model.updateWatermark(wm)
                                }
                        }
                    }
                } else {
                    HStack {
                        Text("已导入图片水印").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("清除") {
                            var wm = model.watermark
                            wm.imageData = nil
                            model.updateWatermark(wm)
                        }
                        .font(.caption)
                    }
                }

                HStack {
                    Text(model.watermark.imageData == nil ? "字号" : "大小").font(.caption).foregroundStyle(.secondary)
                    Slider(
                        value: model.watermark.imageData == nil
                            ? Binding(get: { model.watermark.fontSize }, set: { var wm = model.watermark; wm.fontSize = $0; model.updateWatermark(wm) })
                            : Binding(get: { model.watermark.imageScale }, set: { var wm = model.watermark; wm.imageScale = $0; model.updateWatermark(wm) }),
                        in: model.watermark.imageData == nil ? 16...72 : 0.05...0.4
                    )
                }
                HStack {
                    Text("位置").font(.caption).foregroundStyle(.secondary)
                    Picker("位置", selection: Binding(
                        get: { model.watermark.position },
                        set: { var wm = model.watermark; wm.position = $0; model.updateWatermark(wm) }
                    )) {
                        ForEach(WatermarkSettings.Position.allCases) { p in
                            Text(p.label).tag(p)
                        }
                    }
                    .labelsHidden()
                }
                HStack {
                    Text("透明度").font(.caption).foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { model.watermark.opacity },
                        set: { var wm = model.watermark; wm.opacity = $0; model.updateWatermark(wm) }
                    ), in: 0.05...1.0)
                }
            }
        }
    }

    private func importWatermarkImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) {
            var wm = model.watermark
            wm.imageData = data
            wm.text = ""
            model.updateWatermark(wm)
            model.log("已导入水印图片: \(url.lastPathComponent)")
        }
    }

    /// 视频输出分辨率选择（480p/720p/1080p/4K）。
    private var resolutionPicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("输出分辨率").font(.caption).foregroundStyle(.secondary)
            Picker("分辨率", selection: $model.videoResolution) {
                ForEach(VideoResolution.all, id: \.self) { r in
                    Text(r.label).tag(r)
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
            HStack {
                Text("停顿感").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f×", model.pauseScale)).font(.caption.monospacedDigit())
            }
            Slider(value: $model.pauseScale, in: 0...2, step: 0.1)
        }
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("导出模式").font(.caption).foregroundStyle(.secondary)
            Picker("模式", selection: $model.exportMode) {
                ForEach(AppModel.ExportMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var actionButtons: some View {
        HStack {
            if model.isProcessing {
                Button(role: .destructive) { model.cancelExport() } label: {
                    Label("取消", systemImage: "stop.circle")
                }
            } else {
                Button {
                    model.startExport()
                } label: {
                    Label("开始生成", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.inputKind == nil)
            }
            Spacer()
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
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        // 按 URL 比较（AVURLAsset 的 == 语义不可靠）；避免每次 SwiftUI 更新都重建播放器。
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            nsView.player = AVPlayer(url: url)
        }
    }
}
