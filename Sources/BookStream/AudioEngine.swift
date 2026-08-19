import Foundation
@preconcurrency import AVFoundation
import os

/// 字幕旁白溢出（语音长于字幕窗口）的处理策略。
public enum SubtitleOverflowPolicy: String, CaseIterable, Sendable, Identifiable {
    /// 顺延：语音完整保留，字幕窗口随语音延长，后续条目顺延（默认，语音与字幕始终同步）。
    case extend = "顺延（推荐）"
    /// 截断：严格按原时间轴，语音超过窗口即截断（保持原字幕节奏）。
    case truncate = "截断"

    public var id: String { rawValue }
}

/// 音频管线输出：WAV 路径 + 采样帧精度时间轴 + 生成过程中的告警。
public struct SynthResult: Sendable {
    public let wavURL: URL
    public let segments: [TimedSegment]
    public let warnings: [String]

    public init(wavURL: URL, segments: [TimedSegment], warnings: [String] = []) {
        self.wavURL = wavURL
        self.segments = segments
        self.warnings = warnings
    }
}

/// TTS 离线抓轨引擎。
///
/// 设计要点：
/// - 全部音频工作（合成 / 重采样 / 写盘）运行在**专属 NSThread** 上，禁止主线程参与。
///   实测 `AVSpeechSynthesizer.write(toBufferCallback:)` 的缓冲回调投递到「发起 write
///   的线程」的 run loop：GCD 工作线程无法服务该回调（应用内回调完全不触发），
///   必须使用带活跃 run loop 的专用线程，且该线程 run loop 的**首次交互必须发生在
///   write() 之后**（任何预先的 run/timer 活动都会导致回调不再投递）；
/// - 完成判定完全依赖缓冲回调本身的流终止信号（句尾连续 0 帧空缓冲 + 无后续回调
///   宽限期），不依赖任何 Delegate 回调；
/// - **禁止设置 preUtteranceDelay / postUtteranceDelay**：实测该设置会令
///   write(toBufferCallback:) 的缓冲回调完全不触发（合成静默走了不同路径），抓轨挂死；
/// - 通过 `AVAudioConverter` 把系统动态采样率（实测默认 22050 Hz）统一重采样为
///   44.1 kHz / 16-bit / 单声道 WAV；
/// - 每句时长 = 实际产出的 PCM 帧数 / 44100.0，逐句累加推导全局绝对时间戳。
public final class AudioEngine: @unchecked Sendable {

    /// 专属串行音频线程：init 即启动并常驻转动 run loop。
    private var audioThread: Thread!
    /// 待执行任务 FIFO（串行排队到音频线程执行）。
    private let workLock = NSLock()
    private var workItems: [() -> Void] = []

    /// 目标 PCM：44.1 kHz 单声道 float32（deinterleaved），与 WAV 文件 processingFormat 一致。
    private let pcmMono44k = AVAudioFormat(standardFormatWithSampleRate: AudioFormat.sampleRate, channels: 1)!

    public init() {
        // 重要：线程启动后不得预先触碰 run loop（不加常驻 timer、不先 run）。
        // 实测 `AVSpeechSynthesizer.write(toBufferCallback:)` 的回调投递要求调用线程的
        // run loop 在首次 write 之前处于“全新”状态；任何先前的 run/timer 活动都会导致
        // 回调完全不触发。因此这里仅轮询任务 FIFO，首个 run loop 交互发生在 renderOne
        // 的 write() 之后。
        let thread = Thread { [weak self] in
            while !Thread.current.isCancelled {
                guard let work = self?.takeNextWorkItem() else {
                    Thread.sleep(forTimeInterval: 0.02)
                    continue
                }
                work()
            }
        }
        thread.name = "com.bookstream.audio"
        thread.qualityOfService = .userInitiated
        audioThread = thread
        thread.start()
    }

    private func takeNextWorkItem() -> (() -> Void)? {
        workLock.lock()
        defer { workLock.unlock() }
        guard !workItems.isEmpty else { return nil }
        return workItems.removeFirst()
    }

    private func enqueue(_ item: @escaping () -> Void) {
        workLock.lock()
        workItems.append(item)
        workLock.unlock()
    }

    /// 把同步工作提交到专属音频线程执行并等待结果（串行、非主线程、run loop 常驻）。
    private func syncOnAudioThread<T>(_ work: @escaping () throws -> T) throws -> T {
        if Thread.current === audioThread {
            return try work()
        }
        let box = WorkBox<T>()
        let semaphore = DispatchSemaphore(value: 0)
        enqueue {
            do { box.result = try work() } catch { box.error = error }
            semaphore.signal()
        }
        // 有界等待：音频线程内部已有 10 分钟看门狗，此处 12 分钟兜底，
        // 避免任何意外情况下调用方无限阻塞。
        if semaphore.wait(timeout: .now() + 720) == .timedOut {
            throw BookStreamError.audioRenderFailed("音频线程任务超时（12 分钟）")
        }
        if let error = box.error { throw error }
        guard let result = box.result else {
            throw BookStreamError.audioRenderFailed("音频线程未返回结果")
        }
        return result
    }

    // MARK: - 公开 API（书 → TTS 音频 + SRT 时间轴）

    public func renderBook(
        sentences: [Sentence],
        outputURL: URL,
        voiceIdentifier: String?,
        piperVoice: PiperVoice? = nil,
        rate: Float,
        pauseScale: Float = 1.0,
        progress: @escaping @Sendable @MainActor (Int, Int) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) async throws -> SynthResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.syncOnAudioThread {
                        try self.renderBookSync(
                            sentences: sentences,
                            outputURL: outputURL,
                            voiceIdentifier: voiceIdentifier,
                            piperVoice: piperVoice,
                            rate: rate,
                            pauseScale: pauseScale,
                            progress: progress,
                            cancellation: cancellation
                        )
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 公开 API（字幕 → 按时间轴放置的旁白音频）

    /// 按字幕时间轴放置 TTS 旁白：不足处补静音，超出窗口按策略处理（顺延/截断），
    /// 保证全局时间轴与字幕一致、且语音永不重叠。
    public func renderSubtitleAudio(
        entries: [SubtitleEntry],
        outputURL: URL,
        voiceIdentifier: String?,
        piperVoice: PiperVoice? = nil,
        rate: Float,
        overflowPolicy: SubtitleOverflowPolicy = .extend,
        progress: @escaping @Sendable @MainActor (Int, Int) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) async throws -> SynthResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let result = try self.syncOnAudioThread {
                        try self.renderSubtitleAudioSync(
                            entries: entries,
                            outputURL: outputURL,
                            voiceIdentifier: voiceIdentifier,
                            piperVoice: piperVoice,
                            rate: rate,
                            overflowPolicy: overflowPolicy,
                            progress: progress,
                            cancellation: cancellation
                        )
                    }
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 同步实现（仅在专属音频线程上执行）

    private func renderBookSync(
        sentences: [Sentence],
        outputURL: URL,
        voiceIdentifier: String?,
        piperVoice: PiperVoice?,
        rate: Float,
        pauseScale: Float,
        progress: @escaping @Sendable @MainActor (Int, Int) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> SynthResult {
        try? FileManager.default.removeItem(at: outputURL)
        let file = try makeWAVFile(at: outputURL)
        let synth = AVSpeechSynthesizer()
        let voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let piper = piperVoice.map { _ in PiperTTS() }

        var segments: [TimedSegment] = []
        var frameCursor: Int64 = 0
        let silenceChunk = AVAudioFrameCount(AudioFormat.sampleRateInt)

        for (i, sentence) in sentences.enumerated() {
            if cancellation() { throw BookStreamError.cancelled }

            let startPos = file.framePosition
            let rawBuffers = try renderOne(
                sentence: sentence.text,
                voice: voice,
                rate: rate,
                synthesizer: synth,
                piper: piper,
                piperVoice: piperVoice
            )
            let converted = try convertAll(rawBuffers, to: pcmMono44k)
            for buf in converted {
                try file.write(from: buf)
            }
            let frames = file.framePosition - startPos

            // 句后停顿（真人朗读节奏）：计入本片段时长，字幕随停顿停留
            var pauseFrames: Int64 = 0
            if pauseScale > 0, sentence.pauseAfter > 0 {
                pauseFrames = Int64((sentence.pauseAfter * Double(pauseScale) * AudioFormat.sampleRate).rounded())
                try writeSilence(file, frames: pauseFrames, chunk: silenceChunk)
            }

            segments.append(TimedSegment(
                id: i,
                text: sentence.text,
                startFrame: frameCursor,
                endFrame: frameCursor + frames + pauseFrames
            ))
            frameCursor += frames + pauseFrames

            reportProgress(progress, done: i + 1, total: sentences.count)
        }
        return SynthResult(wavURL: outputURL, segments: segments)
    }

    private func renderSubtitleAudioSync(
        entries: [SubtitleEntry],
        outputURL: URL,
        voiceIdentifier: String?,
        piperVoice: PiperVoice?,
        rate: Float,
        overflowPolicy: SubtitleOverflowPolicy,
        progress: @escaping @Sendable @MainActor (Int, Int) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) throws -> SynthResult {
        try? FileManager.default.removeItem(at: outputURL)
        let file = try makeWAVFile(at: outputURL)
        let synth = AVSpeechSynthesizer()
        let voice = voiceIdentifier.flatMap { AVSpeechSynthesisVoice(identifier: $0) }
        let piper = piperVoice.map { _ in PiperTTS() }

        var cursor: Int64 = 0          // 音频写入位置（采样帧）
        var prevCaptionEnd: Int64 = 0  // 上一条字幕的实际结束位置（避免语音重叠）
        var segments: [TimedSegment] = []
        var warnings: [String] = []
        let silenceChunk = AVAudioFrameCount(AudioFormat.sampleRateInt) // 1 秒静音块

        for (i, entry) in entries.enumerated() {
            if cancellation() { throw BookStreamError.cancelled }

            let entryStart = Int64((entry.start * AudioFormat.sampleRate).rounded())
            let entryEnd = Int64((entry.end * AudioFormat.sampleRate).rounded())

            // 起点：不早于本字幕起点，也不得与上一条仍在播放的语音重叠
            let startFrame = max(entryStart, prevCaptionEnd)
            if startFrame > cursor {
                try writeSilence(file, frames: startFrame - cursor, chunk: silenceChunk)
                cursor = startFrame
            }

            let rawBuffers = try renderOne(
                sentence: entry.text,
                voice: voice,
                rate: rate,
                synthesizer: synth,
                piper: piper,
                piperVoice: piperVoice
            )
            let converted = try convertAll(rawBuffers, to: pcmMono44k)

            switch overflowPolicy {
            case .extend:
                // 语音完整写入；字幕结束 = 窗口与语音实际结束取大者（溢出则顺延）
                for buf in converted {
                    try file.write(from: buf)
                    cursor += Int64(buf.frameLength)
                }
                let captionEnd = max(entryEnd, cursor)
                if cursor < captionEnd {
                    try writeSilence(file, frames: captionEnd - cursor, chunk: silenceChunk)
                    cursor = captionEnd
                }
                if captionEnd > entryEnd {
                    warnings.append("第 \(i + 1) 条旁白超出窗口 \(String(format: "%.2f", Double(captionEnd - entryEnd) / AudioFormat.sampleRate))s，已顺延（语音与字幕保持同步）")
                }
                segments.append(TimedSegment(id: i, text: entry.text, startFrame: startFrame, endFrame: captionEnd))
                prevCaptionEnd = captionEnd

            case .truncate:
                // 严格按窗口：语音超出即截断（保持原字幕节奏）
                var framesBudget = entryEnd - startFrame
                if framesBudget <= 0 {
                    // 窗口非法（end<=start）退化为顺延语义，至少保证语音完整
                    for buf in converted {
                        try file.write(from: buf)
                        cursor += Int64(buf.frameLength)
                    }
                } else {
                    for buf in converted {
                        if framesBudget <= 0 { break }
                        let n = Int64(buf.frameLength)
                        if n <= framesBudget {
                            try file.write(from: buf)
                            cursor += n
                            framesBudget -= n
                        } else {
                            // 截断该缓冲到剩余预算
                            guard let clipped = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: AVAudioFrameCount(framesBudget)) else { break }
                            clipped.frameLength = AVAudioFrameCount(framesBudget)
                            if let src = buf.floatChannelData?[0], let dst = clipped.floatChannelData?[0] {
                                memcpy(dst, src, Int(framesBudget) * MemoryLayout<Float>.size)
                            }
                            try file.write(from: clipped)
                            cursor += framesBudget
                            framesBudget = 0
                            warnings.append("第 \(i + 1) 条旁白超出窗口，已按原时间轴截断")
                        }
                    }
                }
                // 结束位置取窗口与语音实际结束的大者，防止非法窗口产生负时长片段
                let captionEnd = max(entryEnd, cursor)
                if cursor < captionEnd {
                    try writeSilence(file, frames: captionEnd - cursor, chunk: silenceChunk)
                    cursor = captionEnd
                }
                segments.append(TimedSegment(id: i, text: entry.text, startFrame: startFrame, endFrame: captionEnd))
                prevCaptionEnd = captionEnd
            }

            reportProgress(progress, done: i + 1, total: entries.count)
        }
        return SynthResult(wavURL: outputURL, segments: segments, warnings: warnings)
    }

    // MARK: - 底层原语

    /// 单句抓轨：AI（Piper）或系统音色二选一。
    private func renderOne(
        sentence: String,
        voice: AVSpeechSynthesisVoice?,
        rate: Float,
        synthesizer: AVSpeechSynthesizer,
        piper: PiperTTS?,
        piperVoice: PiperVoice?
    ) throws -> [AVAudioPCMBuffer] {
        // ---- AI 音色（本地 Piper）----
        if let piper, let piperVoice {
            return try piper.render(text: sentence, voice: piperVoice, rate: rate)
        }

        // ---- 系统音色（AVSpeechSynthesizer 离线抓轨）----
        let utterance = AVSpeechUtterance(string: sentence)
        utterance.voice = voice
        utterance.rate = rate
        utterance.pitchMultiplier = 1.0
        // 注意：不要设置 preUtteranceDelay / postUtteranceDelay！
        // 实测该设置会令 write(toBufferCallback:) 的缓冲回调完全不触发
        // （合成静默时框架走了不同路径，离线模式下投递失效），导致抓轨挂死。

        let collector = BufferCollector()
        synthesizer.write(utterance) { buffer in
            collector.append(buffer: buffer)
        }

        // 防挂死看门狗：10 分钟超时（离线抓轨不应出现，但保险起见）
        let start = Date()
        while !collector.isComplete {
            if Date().timeIntervalSince(start) > 600 {
                throw BookStreamError.audioRenderFailed("单句抓轨超时: \(sentence.prefix(40))")
            }
            // 关键：离线抓轨的回调投递到「发起 write 的线程」的 run loop，
            // 因此在抓轨线程上短暂驱动其自身 run loop（首次交互须发生在 write 之后）。
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        let buffers = collector.takeBuffers()
        guard !buffers.isEmpty else {
            throw BookStreamError.audioRenderFailed("未产出任何 PCM 数据: \(sentence.prefix(40))")
        }
        return buffers
    }

    /// 统一重采样到 44.1 kHz / 单声道 / float32（AVAudioConverter 拉模式离线转换）。
    private func convertAll(_ buffers: [AVAudioPCMBuffer], to target: AVAudioFormat) throws -> [AVAudioPCMBuffer] {
        guard let first = buffers.first else { return [] }
        guard let converter = AVAudioConverter(from: first.format, to: target) else {
            throw BookStreamError.audioRenderFailed("无法创建转换器: \(first.format) -> \(target)")
        }
        converter.sampleRateConverterQuality = .max

        let feeder = InputFeeder(buffers: buffers)
        var output: [AVAudioPCMBuffer] = []
        let ratio = Double(target.sampleRate) / Double(first.format.sampleRate)
        let capacity = AVAudioFrameCount(max(4096, AVAudioFrameCount(4096.0 * ratio) + 4096))

        conversionLoop: while true {
            let outBuf = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, outStatus -> AVAudioBuffer? in
                guard let next = feeder.next() else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                outStatus.pointee = .haveData
                return next
            }

            switch status {
            case .haveData:
                if outBuf.frameLength > 0 { output.append(outBuf) }
            case .inputRanDry:
                if feeder.isExhausted { break conversionLoop }
            case .endOfStream:
                break conversionLoop
            case .error:
                throw convError ?? BookStreamError.audioRenderFailed("AVAudioConverter 转换失败")
            @unknown default:
                break conversionLoop
            }
        }
        return output
    }

    private func makeWAVFile(at url: URL) throws -> AVAudioFile {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44100.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func writeSilence(_ file: AVAudioFile, frames: Int64, chunk: AVAudioFrameCount) throws {
        var remaining = frames
        while remaining > 0 {
            let n = AVAudioFrameCount(min(Int64(chunk), remaining))
            guard let buf = AVAudioPCMBuffer(pcmFormat: pcmMono44k, frameCapacity: n) else {
                throw BookStreamError.audioRenderFailed("静音缓冲分配失败")
            }
            buf.frameLength = n
            if let data = buf.floatChannelData?[0] {
                memset(data, 0, Int(n) * MemoryLayout<Float>.size)
            }
            try file.write(from: buf)
            remaining -= Int64(n)
        }
    }

    private func reportProgress(
        _ progress: @escaping @Sendable @MainActor (Int, Int) -> Void,
        done: Int,
        total: Int
    ) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                progress(done, total)
            }
        }
    }
}

// MARK: - 内部辅助（Sendable 安全容器）

/// 跨线程工作结果容器（`Thread.perform(waitUntilDone:)` 桥接）。
private final class WorkBox<T>: @unchecked Sendable {
    var result: T?
    var error: Error?
}

/// 收集缓冲回调产出的 PCM，线程安全（回调经音频线程 run loop 投递）。
/// 句尾 0 帧缓冲为流终止信号；`isComplete` 在末段空缓冲后 0.3s 无新回调时成立。
private final class BufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var sawZeroFrame = false
    private var lastCallback = Date.distantPast

    func append(buffer: AVAudioBuffer) {
        lock.lock(); defer { lock.unlock() }
        lastCallback = Date()
        guard let pcm = buffer as? AVAudioPCMBuffer else { return }
        if pcm.frameLength == 0 {
            sawZeroFrame = true
        } else {
            buffers.append(pcm)
        }
    }

    var isComplete: Bool {
        lock.lock(); defer { lock.unlock() }
        guard sawZeroFrame else { return false }
        return Date().timeIntervalSince(lastCallback) > 0.3
    }

    func takeBuffers() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        return buffers
    }
}

/// AVAudioConverter 拉模式输入源（避免在闭包中捕获可变局部变量）。
private final class InputFeeder: @unchecked Sendable {
    private let buffers: [AVAudioPCMBuffer]
    private var index = 0
    private var exhausted = false

    init(buffers: [AVAudioPCMBuffer]) {
        self.buffers = buffers
    }

    var isExhausted: Bool { exhausted }

    func next() -> AVAudioBuffer? {
        guard index < buffers.count else {
            exhausted = true
            return nil
        }
        let b = buffers[index]
        index += 1
        return b
    }
}
