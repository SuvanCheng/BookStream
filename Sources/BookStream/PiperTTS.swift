import Foundation
import AVFoundation
import os

/// 本地 AI 音色（Piper 神经网络 TTS，完全本地离线推理）。
///
/// 资源布局（App Support/BookStream/piper/）：
/// - `models/*.onnx` + `*.onnx.json`：音色模型（从 rhasspy/piper-voices 下载，一次性）
/// - `bin/piper`：可选的原生 piper 二进制（若用户自备）
///
/// 引擎解析顺序：
/// 1. `bin/piper`（原生二进制，自包含）
/// 2. PATH 中的 `piper`
/// 3. `/usr/bin/python3 -m piper`（pip 安装的 piper-tts，本机已验证）
///
/// 首次使用需一次性联网安装引擎/下载模型；此后合成完全离线。
public struct PiperVoice: Sendable, Identifiable, Hashable {
    public let id: String            // 模型文件名（唯一）
    public let displayName: String
    public let language: String      // 如 en_US / zh_CN
    public let modelURL: URL
    public let configURL: URL?

    public init(id: String, displayName: String, language: String, modelURL: URL, configURL: URL?) {
        self.id = id
        self.displayName = displayName
        self.language = language
        self.modelURL = modelURL
        self.configURL = configURL
    }
}

public enum PiperEngine: Sendable, Equatable {
    case notInstalled
    case native(URL)       // 原生二进制
    case python            // /usr/bin/python3 -m piper
}

/// 目录中的一个可下载音色（一“种”人声 = 语言 + 数据集；含其下可用的质量档位）。
public struct PiperCatalogEntry: Sendable, Hashable, Identifiable {
    public let id: String        // 模型名，如 "en_US-lessac"
    public let language: String  // en_US
    public let dataset: String   // lessac
    /// 质量档 → 仓库内规范 .onnx 路径（如 "low" → "en/en_US/lessac/low/en_US-lessac-low.onnx"）。
    /// 下载必须用它（含语言族前缀），否则部分音色 404。
    public let onnxPaths: [String: String]
    public var availableQualities: [String] {
        ["low", "medium", "high"].filter { onnxPaths[$0] != nil }
    }
    public var displayName: String { "\(language)-\(dataset)" }
}

public final class PiperTTS: @unchecked Sendable {

    public static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("BookStream/piper", isDirectory: true)
    }()

    public static let modelsDir: URL = supportDir.appendingPathComponent("models", isDirectory: true)
    public static let binDir: URL = supportDir.appendingPathComponent("bin", isDirectory: true)

    public init() {}

    /// 从 rhasspy/piper-voices 官方仓库的 `voices.json`（权威音色清单）在线拉取
    /// “可下载音色目录”。该文件按音色名给元数据（含 language.code），比遍历目录更可靠。
    /// 会联网（一次性）；失败时由调用方标记并在 UI 提示可稍后重试。
    /// 注：用 curl 抓取（与模型下载同一通道，本机已验证可用），避免 Data(contentsOf:)
    /// 在代理/ATS 环境下失败。
    public static func fetchCatalog() throws -> [PiperCatalogEntry] {
        let remote = "https://huggingface.co/rhasspy/piper-voices/raw/main/voices.json"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("piper-voices-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Self.runCurl(url: remote, output: tmp)
        let data = try Data(contentsOf: tmp)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BookStreamError.audioRenderFailed("目录解析失败")
        }
        // 收集：模型名(语言-数据集) → 语言/数据集/各质量档的规范 .onnx 路径
        var seen: [String: (lang: String, dataset: String, paths: [String: String])] = [:]
        for (name, metaVal) in obj {
            guard let meta = metaVal as? [String: Any],
                  let langNode = meta["language"] as? [String: Any],
                  let langCode = langNode["code"] as? String,
                  let quality = PiperTTS.extractQuality(from: name) else { continue }
            var dataset = name
            // 去掉尾部“-质量”，再去掉开头“语言-”，得到数据集名（如 lessac）
            if name.hasSuffix("-\(quality)") { dataset = String(name.dropLast(quality.count + 1)) }
            if dataset.hasPrefix(langCode + "-") { dataset = String(dataset.dropFirst(langCode.count + 1)) }
            let id = "\(langCode)-\(dataset)"
            // 从 files 里取规范 .onnx 路径（含语言族前缀，如 en/en_US/lessac/low/en_US-lessac-low.onnx）。
            // files 是“路径 -> 元数据”字典，所以路径是 key 而不是 value。
            var onnxPath: String?
            if let files = meta["files"] as? [String: Any] {
                for path in files.keys where path.hasSuffix(".onnx") {
                    onnxPath = path
                    break
                }
            }
            guard let onnxPath else { continue }
            var e = seen[id] ?? (langCode, dataset, [:])
            e.paths[quality] = onnxPath
            seen[id] = e
        }
        return seen.map { kv in
            PiperCatalogEntry(id: kv.key, language: kv.value.lang, dataset: kv.value.dataset,
                              onnxPaths: kv.value.paths)
        }
        .sorted { $0.id < $1.id }
    }

    /// 从音色名（形如 en_US-lessac-low）解析出末尾的质量档（low/medium/high）。
    private static func extractQuality(from name: String) -> String? {
        for q in ["low", "medium", "high"] where name.hasSuffix("-\(q)") { return q }
        return nil
    }

    // MARK: - 引擎检测

    /// 引擎探测结果缓存：`render()` 每句调用 engineStatus()，若不缓存会每句
    /// spawn 一个 python3 检测进程（长篇书 = 数百秒纯开销）。
    private static let engineLock = OSAllocatedUnfairLock(initialState: PiperEngine?.none)

    public static func engineStatus() -> PiperEngine {
        if let cached = engineLock.withLock({ $0 }) { return cached }
        let detected = detectEngine()
        engineLock.withLock { $0 = detected }
        return detected
    }

    /// 安装/卸载引擎后调用，使缓存失效。
    public static func invalidateEngineCache() {
        engineLock.withLock { $0 = nil }
    }

    private static func detectEngine() -> PiperEngine {
        let native = binDir.appendingPathComponent("piper")
        if FileManager.default.isExecutableFile(atPath: native.path) {
            return .native(native)
        }
        // PATH 中的 piper
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for dir in path.split(separator: ":") {
                let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent("piper")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return .native(candidate)
                }
            }
        }
        // python3 -m piper（piper-tts）
        if Self.pythonPiperAvailable() {
            return .python
        }
        return .notInstalled
    }

    private static func pythonPiperAvailable() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", "import piper, sys; print(piper.__version__ if hasattr(piper,'__version__') else 'ok')"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - 模型管理

    /// 判断一个模型文件是否“有效”（非空、且不是 HF 的「Entry not found」等错误占位）。
    private static func isValidModel(_ url: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int, size > 5_000_000 else { return false }
        // 失败占位通常是极小文本（如 “Entry not found”），已由上面 size 阈值排除；
        // onnx 二进制模型体积远大于此，5MB 阈值足够安全。
        return true
    }

    /// 扫描 models 目录下的 .onnx 音色模型（配套 .onnx.json 自动配对）。跳过损坏/占位文件。
    public static func listModels() -> [PiperVoice] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: modelsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        let onnxFiles = files.filter { $0.pathExtension.lowercased() == "onnx" }
        return onnxFiles.compactMap { modelURL in
            guard isValidModel(modelURL) else { return nil }
            let configURL = modelURL.appendingPathExtension("json")
            let hasConfig = FileManager.default.fileExists(atPath: configURL.path)
            let base = modelURL.deletingPathExtension().lastPathComponent
            var name = base
            var lang = "未知"
            if hasConfig, let data = try? Data(contentsOf: configURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let language = json["language"] as? [String: Any], let code = language["code"] as? String {
                    lang = code
                }
                if let dataset = json["dataset"] as? String {
                    name = dataset
                }
            }
            return PiperVoice(
                id: base,
                displayName: name,
                language: lang,
                modelURL: modelURL,
                configURL: hasConfig ? configURL : nil
            )
        }
        .sorted { ($0.language, $0.displayName) < ($1.language, $1.displayName) }
    }

    /// 删除已下载的音色模型（.onnx 与配套 .onnx.json）。音色即从本地移除。
    public static func deleteModel(_ voice: PiperVoice) {
        try? FileManager.default.removeItem(at: voice.modelURL)
        if let configURL = voice.configURL {
            try? FileManager.default.removeItem(at: configURL)
        }
    }

    /// 一次性下载音色模型（rhasspy/piper-voices）。此后完全离线。
    /// 若指定 quality 无效（该档位不存在/下载失败），会**自动回退**到 low 档，
    /// 保证按钮点击总能拿到可用音色。
    public static func downloadModel(
        language: String,          // 如 en_US / zh_CN
        dataset: String,           // 如 lessac / huayan
        quality: String = "medium" // low / medium / high
    ) throws -> PiperVoice {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        // 优先尝试指定档位
        do {
            return try downloadAtQuality(language: language, dataset: dataset, quality: quality)
        } catch {
            // 若指定档位无效/缺失，且不是 low，则回退到 low 再试一次
            if quality.lowercased() != "low" {
                if let low = try? downloadAtQuality(language: language, dataset: dataset, quality: "low") {
                    return low
                }
            }
            throw error
        }
    }

    private static func downloadAtQuality(
        language: String,
        dataset: String,
        quality: String
    ) throws -> PiperVoice {
        let base = "\(language)-\(dataset)-\(quality)"
        let modelURL = modelsDir.appendingPathComponent("\(base).onnx")
        let configURL = modelsDir.appendingPathComponent("\(base).onnx.json")
        // 若已存在但为损坏/占位文件，先删除再下载，避免“Entry not found”假成功。
        if FileManager.default.fileExists(atPath: modelURL.path), !Self.isValidModel(modelURL) {
            try? FileManager.default.removeItem(at: modelURL)
            try? FileManager.default.removeItem(at: configURL)
        }
        guard !FileManager.default.fileExists(atPath: modelURL.path) else {
            return try loadExisting(base: base, modelURL: modelURL, configURL: configURL)
        }
        let remoteBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        let remoteModel = "\(remoteBase)\(language)/\(dataset)/\(quality)/\(base).onnx"
        let remoteConfig = "\(remoteBase)\(language)/\(dataset)/\(quality)/\(base).onnx.json"
        try Self.runCurl(url: remoteModel, output: modelURL)
        try? Self.runCurl(url: remoteConfig, output: configURL)
        // 下载后校验：无效则抛错，避免把坏文件当“成功”写入列表。
        guard Self.isValidModel(modelURL) else {
            try? FileManager.default.removeItem(at: modelURL)
            throw BookStreamError.audioRenderFailed("下载的模型无效或缺失（可能是 URL 地址不存在）: \(base)")
        }
        return try loadExisting(base: base, modelURL: modelURL, configURL: configURL)
    }

    /// 按目录条目 + 质量档下载（使用 voices.json 提供的规范路径，含语言族前缀）。
    /// 指定档位不可用/下载失败时自动回退到该音色实际存在的档位
    /// （优先更低档；medium 优先于 high），保证点击总能拿到可用音色。
    public static func downloadCanonical(
        catalogEntry: PiperCatalogEntry,
        quality: String
    ) throws -> PiperVoice {
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        let requested = quality.lowercased()
        // 期望度排序：指定档位 > low > medium > high（仅在该音色确实存在该档位时尝试）
        var tries = [requested]
        for q in ["low", "medium", "high"] where q != requested && catalogEntry.onnxPaths[q] != nil {
            tries.append(q)
        }
        var lastError: Error?
        for q in tries {
            guard let onnxPath = catalogEntry.onnxPaths[q] else { continue }
            do {
                return try downloadCanonicalPath(onnxPath: onnxPath, baseName: catalogEntry.id + "-" + q)
            } catch { lastError = error }
        }
        throw lastError ?? BookStreamError.audioRenderFailed(
            "该音色无可下载档位（可能文件缺失）: \(catalogEntry.id)"
        )
    }

    private static func downloadCanonicalPath(onnxPath: String, baseName: String) throws -> PiperVoice {
        let modelURL = modelsDir.appendingPathComponent("\(baseName).onnx")
        let configURL = modelsDir.appendingPathComponent("\(baseName).onnx.json")
        if FileManager.default.fileExists(atPath: modelURL.path), !Self.isValidModel(modelURL) {
            try? FileManager.default.removeItem(at: modelURL)
            try? FileManager.default.removeItem(at: configURL)
        }
        guard !FileManager.default.fileExists(atPath: modelURL.path) else {
            return try loadExisting(base: baseName, modelURL: modelURL, configURL: configURL)
        }
        let remoteBase = "https://huggingface.co/rhasspy/piper-voices/resolve/main/"
        try Self.runCurl(url: remoteBase + onnxPath, output: modelURL)
        try? Self.runCurl(url: remoteBase + onnxPath + ".json", output: configURL)
        guard Self.isValidModel(modelURL) else {
            try? FileManager.default.removeItem(at: modelURL)
            throw BookStreamError.audioRenderFailed("下载的模型无效或缺失（URL 可能不存在）: \(baseName)")
        }
        return try loadExisting(base: baseName, modelURL: modelURL, configURL: configURL)
    }

    private static func loadExisting(base: String, modelURL: URL, configURL: URL) throws -> PiperVoice {
        let hasConfig = FileManager.default.fileExists(atPath: configURL.path)
        var name = base
        var lang = "未知"
        if hasConfig, let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let language = json["language"] as? [String: Any], let code = language["code"] as? String { lang = code }
            if let dataset = json["dataset"] as? String { name = dataset }
        }
        return PiperVoice(id: base, displayName: name, language: lang, modelURL: modelURL, configURL: hasConfig ? configURL : nil)
    }

    private static func runCurl(url: String, output: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-sL", "--max-time", "600", "-o", output.path, url]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else {
            throw BookStreamError.audioRenderFailed("下载音色失败: \(url)")
        }
    }

    // MARK: - 合成

    /// 渲染一句文本为模型原生格式 PCM 缓冲（通常 16/22.05kHz 单声道，调用方负责重采样）。
    public func render(text: String, voice: PiperVoice, rate: Float) throws -> [AVAudioPCMBuffer] {
        let engine = Self.engineStatus()
        guard engine != .notInstalled else {
            throw BookStreamError.audioRenderFailed("未安装本地 AI 引擎（需 python3 -m piper 或原生 piper）")
        }

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let inputURL = tmpDir.appendingPathComponent("piper-in-\(UUID().uuidString).txt")
        let outputURL = tmpDir.appendingPathComponent("piper-out-\(UUID().uuidString).wav")
        defer { try? fm.removeItem(at: inputURL); try? fm.removeItem(at: outputURL) }
        try text.write(to: inputURL, atomically: true, encoding: .utf8)

        let lengthScale = String(format: "%.2f", Self.lengthScale(forRate: rate))
        let proc = Process()
        var args: [String] = []
        switch engine {
        case .native(let url):
            proc.executableURL = url
        case .python:
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            args += ["-m", "piper"]
        case .notInstalled:
            throw BookStreamError.audioRenderFailed("未安装本地 AI 引擎")
        }
        args += [
            "-m", voice.modelURL.path,
            "-i", inputURL.path,
            "-f", outputURL.path,
            "--length-scale", lengthScale,
            // 压掉句尾默认静音（Piper 每句末尾会自动加一小段静音，
            // 字幕模式下大量句子会累积成可观的顺延漂移）。
            "--sentence-silence", "0.05",
        ]
        if let config = voice.configURL {
            args += ["-c", config.path]
        }
        proc.arguments = args
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0, fm.fileExists(atPath: outputURL.path) else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BookStreamError.audioRenderFailed(
                "AI 合成失败（退出码 \(proc.terminationStatus)）: \(text.prefix(40))\(stderr.isEmpty ? "" : " · \(stderr.prefix(200))")"
            )
        }

        let file = try AVAudioFile(forReading: outputURL)
        var buffers: [AVAudioPCMBuffer] = []
        // 注意：读到 EOF 时 read(into:) 会抛 _GenericObjCError（而非返回 0 帧），
        // 因此用 framePosition < length 控制读取，避免越界读取触发该错误。
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            buffers.append(buf)
        }
        guard !buffers.isEmpty else {
            throw BookStreamError.audioRenderFailed("AI 合成未产出音频: \(text.prefix(40))")
        }
        return buffers
    }

    /// 批量合成一批句子：**用一个 Python 进程**加载模型一次，连续合成 `texts` 里各项，
    /// 返回与输入一一对应的逐句 `[AVAudioPCMBuffer]`（模型原生采样率、float32 单声道）。
    ///
    /// 相比逐句各起一个子进程，把「进程启动 + 模型加载」的开销摊到一批上，长书渲染可省约 5×。
    /// 时间轴仍按逐句时长精确划分（每句的缓冲时长即其真实朗读时长），与逐句路径完全一致。
    ///
    /// stdout 只作为二进制帧流（避免 print 污染）：每句写 `[int64 sampleRate][int64 sampleCount][sampleCount*4 字节 float32]`。
    /// 空/纯标点句产出 sampleCount=0 的帧。
    public func renderBatch(
        texts: [String],
        voice: PiperVoice,
        rate: Float
    ) throws -> [[AVAudioPCMBuffer]] {
        guard texts.count <= 2048, !texts.isEmpty else {
            throw BookStreamError.audioRenderFailed("批量合成句数非法（1...2048）")
        }
        guard PiperTTS.engineStatus() == .python else {
            // 原生引擎不支持批量，退回逐句
            return try texts.map { try render(text: $0, voice: voice, rate: rate) }
        }

        let fm = FileManager.default
        let tmpDir = fm.temporaryDirectory
        let inputURL = tmpDir.appendingPathComponent("piper-batch-in-\(UUID().uuidString).jsonl")
        let outputURL = tmpDir.appendingPathComponent("piper-batch-out-\(UUID().uuidString).raw")
        defer { try? fm.removeItem(at: inputURL); try? fm.removeItem(at: outputURL) }

        // 等待：确保模型加载完成再写 stdin（脚本首部会向 stdout 写 READY 标记）
        let lengthScale = String(format: "%.2f", Self.lengthScale(forRate: rate))
        let script = PiperTTS.batchScript
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = ["-c", script, voice.modelURL.path, voice.configURL?.path ?? "", lengthScale]
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe
        try proc.run()

        // 写输入：一批 JSON 数组一行（脚本按行读）
        let json = try JSONSerialization.data(withJSONObject: texts)
        let fh = stdinPipe.fileHandleForWriting
        try fh.write(contentsOf: json)
        try fh.write(contentsOf: Data([0x0A]))   // 换行 = 结束一批
        try fh.close()

        // 读 stdout 帧并构建逐句缓冲
        let out = stdoutPipe.fileHandleForReading
        var buffers: [[AVAudioPCMBuffer]] = []
        buffers.reserveCapacity(texts.count)
        for _ in 0..<texts.count {
            guard let header = try Self.readExact(from: out, count: 16), header.count == 16 else {
                break
            }
            let sr = header[0..<8].withUnsafeBytes { $0.load(as: Int64.self) }
            let count = header[8..<16].withUnsafeBytes { $0.load(as: Int64.self) }
            let bytes = Int(count) * 4
            guard let raw = try Self.readExact(from: out, count: bytes) else {
                break
            }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(sr), channels: 1),
                  let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                break
            }
            let len = min(Int(count) * 4, raw.count)
            if len > 0, let dst = buf.floatChannelData?[0] {
                raw.prefix(len).withUnsafeBytes { src in
                    let ptr = src.baseAddress!.assumingMemoryBound(to: Float.self)
                    dst.update(from: ptr, count: len / 4)
                }
            }
            buf.frameLength = AVAudioFrameCount(len / 4)
            buffers.append([buf])
        }

        proc.waitUntilExit()
        if proc.terminationStatus != 0 || buffers.count != texts.count {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BookStreamError.audioRenderFailed(
                "AI 批量合成失败（退出码 \(proc.terminationStatus)）: \(stderr.prefix(200))"
            )
        }
        return buffers
    }

    /// Python 常驻合成脚本：一次加载模型、按 stdin 逐行(JSON)持续合成，句以二进制帧写回 stdout。
    private static let batchScript = """
    import sys,json,struct,os
    import numpy as np
    import piper
    model,config=sys.argv[1],sys.argv[2]
    length_scale=float(sys.argv[3])
    v=piper.PiperVoice.load(model,config or None)
    sr=int(v.config.sample_rate)
    os.write(2,("READY sr=%d\\n"%sr).encode())
    out=os.fdopen(sys.stdout.fileno(),"wb")
    def synth(t):
        if not any(c.isalnum() for c in t.strip()):
            return b""
        try:
            cfg=piper.SynthesisConfig(length_scale=length_scale)
            data=b""
            for ch in v.synthesize(t,cfg):
                data+=np.asarray(ch.audio_float_array,np.float32).tobytes()
            return data
        except Exception as e:
            os.write(2,("PYERR %r\\n"%e).encode()); return b""
    for line in sys.stdin:
        for t in json.loads(line):
            raw=synth(t)
            out.write(struct.pack("<qq",sr,len(raw)//4)); out.write(raw); out.flush()
    """

    /// 从 FileHandle 精确读取指定字节数（循环读取直到读满 count 字节或 EOF）。
    private static func readExact(from handle: FileHandle, count: Int) throws -> Data? {
        guard count > 0 else { return Data() }
        var result = Data()
        result.reserveCapacity(count)
        while result.count < count {
            guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else {
                return result.isEmpty ? nil : result
            }
            result.append(chunk)
        }
        return result
    }

    /// 把 App 的语速（AVSpeech 0.2~0.6，默认 0.5）映射为 piper 的 length-scale（>1 更慢）。
    /// 校准：Piper 默认（length 1.0）比 AVSpeech 默认（rate 0.5）朗读明显偏慢，导致
    /// 字幕窗口被逐条顺延、视频被拉长。把基线压到 0.82，使 0.5 档的 AI 节奏贴近系统音色；
    /// 随语速单调：越低越慢、越高越快。
    private static func lengthScale(forRate rate: Float) -> Float {
        let scale = 0.82 + (0.5 - rate) * 1.2
        return min(max(scale, 0.6), 1.6)
    }
}
