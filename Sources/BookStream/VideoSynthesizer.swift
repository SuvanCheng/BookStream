import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import AppKit

// MARK: - 字幕样式（可调色）

/// 纯 RGB 颜色（跨隔离域 Sendable 传递，可持久化）。
public struct CaptionColor: Sendable, Hashable, Codable {
    public let red: Double
    public let green: Double
    public let blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public var nsColor: NSColor {
        NSColor(calibratedRed: red, green: green, blue: blue, alpha: 1.0)
    }

    public static let vividOrange = CaptionColor(red: 1.00, green: 0.55, blue: 0.00)
    public static let white       = CaptionColor(red: 1.00, green: 1.00, blue: 1.00)
    public static let red         = CaptionColor(red: 1.00, green: 0.29, blue: 0.29)
    public static let yellow      = CaptionColor(red: 1.00, green: 0.80, blue: 0.20)
    public static let green       = CaptionColor(red: 0.30, green: 0.90, blue: 0.45)
    public static let cyan        = CaptionColor(red: 0.25, green: 0.85, blue: 0.90)
    public static let blue        = CaptionColor(red: 0.35, green: 0.65, blue: 1.00)
    public static let purple      = CaptionColor(red: 0.80, green: 0.45, blue: 1.00)
    public static let pink        = CaptionColor(red: 1.00, green: 0.45, blue: 0.75)
}

/// 滚动字幕排版样式。
public struct CaptionStyle: Sendable {
    public let highlight: CaptionColor
    public let normal: CaptionColor
    public let scrollSpeed: Double // 像素/秒，控制字幕上滚速度

    public init(highlight: CaptionColor = .vividOrange, normal: CaptionColor = .white, scrollSpeed: Double = 55) {
        self.highlight = highlight
        self.normal = normal
        self.scrollSpeed = scrollSpeed
    }
}

/// 水印设置（文本或图片；位置/大小/透明度可调，可持久化）。
public struct WatermarkSettings: Sendable, Codable, Equatable {
    public enum Position: String, CaseIterable, Codable, Identifiable, Sendable {
        case topLeft, topCenter, topRight
        case midLeft, center, midRight
        case bottomLeft, bottomCenter, bottomRight
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .topLeft: return "左上"
            case .topCenter: return "上中"
            case .topRight: return "右上"
            case .midLeft: return "左中"
            case .center: return "正中"
            case .midRight: return "右中"
            case .bottomLeft: return "左下"
            case .bottomCenter: return "下中"
            case .bottomRight: return "右下"
            }
        }
    }

    public var enabled: Bool
    public var text: String
    public var color: CaptionColor
    public var fontSize: Double        // 相对 1080p 的字号（随分辨率缩放）
    public var opacity: Double         // 0-1
    public var position: Position
    public var imageData: Data?        // 导入的图片（PNG/JPEG）；nil = 文本水印
    public var imageScale: Double      // 图片宽度相对画布宽度比例（0.05-0.4）

    public init(
        enabled: Bool = false,
        text: String = "BookStream",
        color: CaptionColor = .white,
        fontSize: Double = 36,
        opacity: Double = 0.35,
        position: Position = .bottomRight,
        imageData: Data? = nil,
        imageScale: Double = 0.12
    ) {
        self.enabled = enabled
        self.text = text
        self.color = color
        self.fontSize = fontSize
        self.opacity = opacity
        self.position = position
        self.imageData = imageData
        self.imageScale = imageScale
    }

    public static let `default` = WatermarkSettings()
}

/// 视频输出分辨率预设（含推荐码率）。
public struct VideoResolution: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let bitrate: Int
    public let label: String

    public init(width: Int, height: Int, bitrate: Int, label: String) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.label = label
    }

    public static let p480  = VideoResolution(width: 854,  height: 480,  bitrate: 1_500_000, label: "480p")
    public static let p720  = VideoResolution(width: 1280, height: 720,  bitrate: 3_500_000, label: "720p")
    public static let p1080 = VideoResolution(width: 1920, height: 1080, bitrate: 6_000_000, label: "1080p")
    public static let p4k   = VideoResolution(width: 3840, height: 2160, bitrate: 20_000_000, label: "4K")

    public static let all: [VideoResolution] = [.p480, .p720, .p1080, .p4k]
}

/// 动态字幕排版视频渲染器。
///
/// 两阶段离线管线：
/// 1. `AVAssetReader` 读取 WAV 音频流推入 `AVAssetWriter` 音频输入（AAC 44.1 kHz 128 kbps）；
/// 2. 按 30 fps 逐帧渲染「从下往上滚动」的字幕流：当前句进入中心高亮区即开始，
///    上方为已淡出的历史字幕，下方为即将到来的字幕（CoreText 排版进 `CVPixelBufferPool`
///    复用的 32BGRA 像素缓冲），推入视频输入（H.264 硬件编码，分辨率/码率可按
///    `VideoResolution` 选择 480p/720p/1080p/4K，默认 1080p）。
///
/// 背压与时钟同步：
/// - 视频 PTS = frameIndex / 30，音频 PTS = sampleCount / 44100（来自 WAV 采样缓冲自身 PTS）；
/// - 单一串行队列交替驱动，严格检查 `isReadyForMoreMediaData`，任一输入未就绪即短暂让步重试，
///   杜绝阻塞挂起与并发锁死（实测 AVAssetWriter 必须在创建它的同一串行队列线程上驱动）；
/// - 每帧在 `autoreleasepool` 内分配像素缓冲并即时解锁复用。
public final class VideoRenderer: @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.bookstream.video", qos: .userInitiated)
    private var width = 1920
    private var height = 1080
    private let fps: Int32 = 30

    /// 调试帧转储目录（环境变量 BOOKSTREAM_FRAMEDUMP 指定时启用）。
    static let frameDumpDir: String? = ProcessInfo.processInfo.environment["BOOKSTREAM_FRAMEDUMP"]
    /// 转储间隔（帧数）；环境变量非法/≤0 时回退 30，避免除零。
    static let frameDumpEvery: Int = max(1, Int(ProcessInfo.processInfo.environment["BOOKSTREAM_FRAMEDUMP_EVERY"] ?? "") ?? 30)

    public init() {}

    public func render(
        audioURL: URL,
        segments: [TimedSegment],
        outputURL: URL,
        style: CaptionStyle,
        resolution: VideoResolution = .p1080,
        watermark: WatermarkSettings = .default,
        progress: @escaping @Sendable @MainActor (Double) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) async throws {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try self.renderSync(
                        audioURL: audioURL,
                        segments: segments,
                        outputURL: outputURL,
                        style: style,
                        resolution: resolution,
                        watermark: watermark,
                        progress: progress,
                        cancellation: cancellation
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 同步实现（仅在专属串行队列上执行）

    private func renderSync(
        audioURL: URL,
        segments: [TimedSegment],
        outputURL: URL,
        style: CaptionStyle,
        resolution: VideoResolution,
        watermark: WatermarkSettings,
        progress: @escaping @Sendable @MainActor (Double) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) throws {
        // 应用所选分辨率（width/height 供内部帧合成使用）
        self.width = resolution.width
        self.height = resolution.height
        try? FileManager.default.removeItem(at: outputURL)

        // ---- 1. 音频读取端 ----
        let asset = AVURLAsset(url: audioURL)
        let track = try loadAudioTrack(from: asset)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ])
        guard reader.canAdd(readerOutput) else {
            throw BookStreamError.videoRenderFailed("无法添加音频读取输出")
        }
        reader.add(readerOutput)
        guard reader.startReading(), reader.status == .reading else {
            throw BookStreamError.videoRenderFailed(reader.error?.localizedDescription ?? "AVAssetReader 启动失败")
        }

        let audioFile = try AVAudioFile(forReading: audioURL)
        let totalAudioFrames = audioFile.length
        let totalVideoFrames = Int64(ceil(Double(totalAudioFrames) / AudioFormat.sampleRate * Double(fps)))
        let totalDuration = Double(totalAudioFrames) / AudioFormat.sampleRate
        guard totalVideoFrames > 0 else {
            throw BookStreamError.videoRenderFailed("音频为空")
        }

        // ---- 2. 写入端 ----
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = false

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: resolution.bitrate,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoAllowFrameReorderingKey: false,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as NSDictionary,
            ]
        )

        guard writer.canAdd(audioInput), writer.canAdd(videoInput) else {
            throw BookStreamError.videoRenderFailed("无法添加音视频输入")
        }
        writer.add(audioInput)
        writer.add(videoInput)
        guard writer.startWriting() else {
            throw BookStreamError.videoRenderFailed(writer.error?.localizedDescription ?? "AVAssetWriter 启动失败")
        }
        writer.startSession(atSourceTime: .zero)

        // ---- 3. 像素缓冲池：使用写入器适配器提供的池（IOSurface 缓冲，
        //      编码器可直接消费；自建内存池曾被实测导致 H.264 编码器不排空而停滞）----
        guard let pool = adaptor.pixelBufferPool else {
            throw BookStreamError.videoRenderFailed("无法获取像素缓冲池")
        }

        // ---- 4. 主循环：单队列交替驱动音视频，PTS 对齐 + 背压让步 ----
        let sortedSegments = segments.sorted { $0.startFrame < $1.startFrame }
        var videoIndex: Int64 = 0
        var pendingAudio: CMSampleBuffer?
        var audioDone = false
        var audioFinished = false
        var layoutCache: [Int: LineLayout] = [:]
        // 进度看门狗：任一输入端长时间无进展（编码器停滞/池耗尽）时中止，避免静默死循环
        var lastProgress = Date()
        var lastProgressVideoIndex: Int64 = -1
        var lastAudioAppended: Int64 = 0
        var audioAppendedCount: Int64 = 0

        while videoIndex < totalVideoFrames || pendingAudio != nil || !audioDone {
            if cancellation() { throw BookStreamError.cancelled }

            if pendingAudio == nil && !audioDone {
                if let buf = readerOutput.copyNextSampleBuffer() {
                    pendingAudio = buf
                } else {
                    audioDone = true
                }
            }

            let videoTime = Double(videoIndex) / Double(fps)
            var appended = false

            // 音频：只要有就绪就追加（不做 PTS 节流）。
            // 实测「按视频时间节流音频」会与写入器的队列背压形成环形等待：
            // 视频队列满 → 视频停 → 音频被节流停 → 写入器不再排空 → 视频队列永远满。
            // 让音频尽量推进，写入器即可持续消费两轨。
            if let buf = pendingAudio {
                if audioInput.isReadyForMoreMediaData {
                    if audioInput.append(buf) {
                        pendingAudio = nil
                        audioAppendedCount += 1
                        appended = true
                    }
                }
            }

            // 音频完全消费后尽早 markAsFinished，让 Muxer 停止等待音频轨、
            // 避免它拖住视频轨的排空（实测可消除小分辨率下的编码停滞）。
            if !audioFinished && audioDone && pendingAudio == nil {
                audioInput.markAsFinished()
                audioFinished = true
            }

            // 视频：逐帧追加（滚动字幕渲染）
            if !appended && videoIndex < totalVideoFrames {
                if videoInput.isReadyForMoreMediaData {
                    autoreleasepool {
                        if let pixelBuffer = makeFrame(
                            segments: sortedSegments,
                            videoTime: videoTime,
                            totalDuration: totalDuration,
                            style: style,
                            watermark: watermark,
                            layoutCache: &layoutCache,
                            pool: pool
                        ) {
                            let pts = CMTime(value: videoIndex, timescale: fps)
                            if adaptor.append(pixelBuffer, withPresentationTime: pts) {
                                videoIndex += 1
                                appended = true
                            }
                        }
                    }
                }
            }

            if !appended {
                // 背压让步：任一输入端未就绪时短暂让出，绝不阻塞等待
                Thread.sleep(forTimeInterval: 0.005)
            }

            // 进度看门狗：60 秒无任何进展 → 判定编码停滞
            if videoIndex != lastProgressVideoIndex {
                lastProgressVideoIndex = videoIndex
                lastProgress = Date()
            } else if audioAppendedCount != lastAudioAppended {
                lastAudioAppended = audioAppendedCount
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > 60 {
                throw BookStreamError.videoRenderFailed(
                    "编码写入停滞（videoIndex=\(videoIndex)/\(totalVideoFrames) videoReady=\(videoInput.isReadyForMoreMediaData) audioReady=\(audioInput.isReadyForMoreMediaData) pending=\(pendingAudio?.presentationTimeStamp.seconds ?? -1) audioDone=\(audioDone)）"
                )
            }

            if videoIndex % 30 == 0 {
                let p = Double(videoIndex) / Double(max(totalVideoFrames, 1))
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { progress(p) }
                }
            }
        }

        if !audioFinished { audioInput.markAsFinished() }
        videoInput.markAsFinished()
        reader.cancelReading()

        guard reader.status != .failed else {
            throw BookStreamError.videoRenderFailed(reader.error?.localizedDescription ?? "AVAssetReader 读取失败")
        }

        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        // 有界等待：finishWriting 理论上应在排空后回调，但编码停滞时可能迟迟不返回。
        // 设 120s 上限，超时抛错而非无限挂起（配合主循环看门狗双保险）。
        if semaphore.wait(timeout: .now() + 120) == .timedOut {
            throw BookStreamError.videoRenderFailed("finishWriting 超时（\(writer.status.rawValue)，可能编码未排空）")
        }
        guard writer.status == .completed else {
            throw BookStreamError.videoRenderFailed(writer.error?.localizedDescription ?? "写入失败(\(writer.status.rawValue))")
        }
    }

    /// 同步读取音频轨道：桥接 async `loadTracks(withMediaType:)`（避免已废弃的同步 API），
    /// 调用方仍处于专属串行队列的同步上下文。
    private func loadAudioTrack(from asset: AVURLAsset) throws -> AVAssetTrack {
        let box = TrackLoadBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do {
                box.tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                box.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let error = box.error { throw error }
        guard let track = box.tracks.first else {
            throw BookStreamError.videoRenderFailed("音频轨道缺失")
        }
        return track
    }

    // MARK: - 滚动字幕渲染

    /// 缓存的单行排版（framesetter + 尺寸），按 (id, 是否高亮) 双键缓存。
    private struct LineLayout {
        let framesetter: CTFramesetter
        let size: CGSize
    }

    private func cacheKey(_ id: Int, highlight: Bool) -> Int {
        id * 2 + (highlight ? 1 : 0)
    }

    /// 从下往上滚动字幕流（恒定速度、当前句锚定中心，无重叠）：
    /// - 当前句固定画面中心（高亮 + 72pt 粗体），整句朗读期间静止，观感稳定丝滑；
    /// - 已结束历史句以固定速度上滚并淡出；未开始未来句以同速接近、线性滚动；
    /// - 所有行按「行高均值 + 间隙」间距约束，杜绝重叠；
    /// - 排版按 (id, 是否高亮) 双键缓存，跨帧复用，无逐帧重建。
    private func drawRollingCaptions(
        in ctx: CGContext,
        time: Double,
        segments: [TimedSegment],
        layoutCache: inout [Int: LineLayout],
        style: CaptionStyle,
        canvas: CGSize
    ) {
        guard !segments.isEmpty else { return }
        // 所有布局量按画布高度相对 1080p 等比缩放（480p/720p/1080p/4K 观感一致）。
        let scale = canvas.height / 1080.0
        let centerY = canvas.height / 2
        let speed = CGFloat(style.scrollSpeed) * scale
        let halfWindow: CGFloat = 640 * scale
        let rangeSeconds = Double(halfWindow) / Double(speed)

        let lo = lowerBound(segments: segments, startAtLeast: time - rangeSeconds)
        let hi = upperBound(segments: segments, startAtMost: time + rangeSeconds)
        guard lo < hi else { return }
        let maxWidth = canvas.width - 200 * scale
        let minGap: CGFloat = 22 * scale

        // ---- 1. 判定当前句 ----
        var currentIdx: Int?
        for i in lo..<hi where time >= segments[i].start && time < segments[i].end {
            currentIdx = i
            break
        }

        // ---- 2. 确保排版缓存存在（同时得到各句行高）----
        var heights: [Int: CGFloat] = [:]
        for i in lo..<hi {
            let seg = segments[i]
            let isCurrent = (i == currentIdx)
            let key = cacheKey(seg.id, highlight: isCurrent)
            let layout: LineLayout
            if let cached = layoutCache[key] {
                layout = cached
            } else {
                let font = NSFont.systemFont(
                    ofSize: (isCurrent ? 72 : 44) * scale,
                    weight: isCurrent ? .bold : .regular
                )
                let color = (isCurrent ? style.highlight : style.normal).nsColor
                layout = makeLineLayout(text: seg.text, font: font, color: color, maxWidth: maxWidth)
                layoutCache[key] = layout
            }
            heights[i] = layout.size.height
        }

        func spacing(_ a: Int, _ b: Int) -> CGFloat {
            (heights[a]! + heights[b]!) / 2 + minGap
        }

        // ---- 3. 定位（坐标系：y 向上为正，y=0 底边、y=H 顶边；当前句锚定中心）----
        // 关键修正：CTFrameDraw 在非翻转的 CGBitmapContext 中直接输出正向文字；
        // 此前加了 translate+scale(-1) 翻转，实测导致文字整体旋转 180°（上下颠倒+左右镜像）。
        var yCenter: [Int: CGFloat] = [:]

        if let ci = currentIdx {
            yCenter[ci] = centerY
            // 历史（上方，y 更大）：从当前句向上约束
            if ci > lo {
                for i in stride(from: ci - 1, through: lo, by: -1) {
                    let raw = centerY + CGFloat(time - segments[i].end) * speed
                    yCenter[i] = max(raw, yCenter[i + 1]! + spacing(i, i + 1))
                }
            }
            // 未来（下方，y 更小）：从当前句向下约束
            if ci + 1 < hi {
                for i in (ci + 1)..<hi {
                    let raw = centerY - CGFloat(segments[i].start - time) * speed
                    yCenter[i] = min(raw, yCenter[i - 1]! - spacing(i - 1, i))
                }
            }
        } else {
            // 无当前句（间隙）：以「下一句」为锚点（不钉在中心，仅用于约束）
            let nxt = upperBound(segments: segments, startAtMost: time)
            if nxt >= hi {
                // 全部为历史：从中心向上堆叠
                for i in stride(from: hi - 1, through: lo, by: -1) {
                    let raw = centerY + CGFloat(time - segments[i].end) * speed
                    yCenter[i] = (i + 1 < hi) ? max(raw, yCenter[i + 1]! + spacing(i, i + 1)) : raw
                }
            } else if nxt <= lo {
                // 全部为未来：向中心上移接近
                for i in lo..<hi {
                    let raw = centerY - CGFloat(segments[i].start - time) * speed
                    yCenter[i] = (i > lo) ? min(raw, yCenter[i - 1]! - spacing(i - 1, i)) : raw
                }
            } else {
                // 锚点下一句在窗口内
                yCenter[nxt] = centerY - CGFloat(segments[nxt].start - time) * speed
                if nxt > lo {
                    for i in stride(from: nxt - 1, through: lo, by: -1) {
                        let raw = centerY + CGFloat(time - segments[i].end) * speed
                        yCenter[i] = max(raw, yCenter[i + 1]! + spacing(i, i + 1))
                    }
                }
                if nxt + 1 < hi {
                    for i in (nxt + 1)..<hi {
                        let raw = centerY - CGFloat(segments[i].start - time) * speed
                        yCenter[i] = min(raw, yCenter[i - 1]! - spacing(i - 1, i))
                    }
                }
            }
        }

        // ---- 4. 直接绘制（不再翻转坐标系；先画普通行，再画当前行保证层级）----
        func drawLine(_ i: Int, isCurrent: Bool) {
            let seg = segments[i]
            guard let y = yCenter[i], let layout = layoutCache[cacheKey(seg.id, highlight: isCurrent)] else { return }
            guard y > -320 * scale, y < canvas.height + 320 * scale else { return }

            let alpha: CGFloat
            if isCurrent {
                alpha = 1.0
            } else if time < seg.start {
                let remaining = CGFloat(seg.start - time)
                alpha = min(1.0, max(0.35, 1.0 - remaining / 3.0 * 0.65))
            } else {
                let age = CGFloat(time - seg.end)
                alpha = max(0.30, 1.0 - age / 5.0 * 0.70)
            }

            let w = min(layout.size.width, maxWidth)
            let h = layout.size.height
            let rect = CGRect(x: (canvas.width - w) / 2, y: y - h / 2, width: w, height: h)

            // 纯色高对比文字直接绘制，无需投影也无需 save/restore：
            // 每帧都是全新 CGContext，且不再是纯黑底上不可见的投影所需的离屏开销。
            ctx.setAlpha(alpha)
            let path = CGPath(rect: rect, transform: nil)
            let frame = CTFramesetterCreateFrame(layout.framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)
        }

        for i in lo..<hi where i != currentIdx {
            drawLine(i, isCurrent: false)
        }
        if let ci = currentIdx {
            drawLine(ci, isCurrent: true)
        }
    }


    private func makeLineLayout(text: String, font: NSFont, color: NSColor, maxWidth: CGFloat) -> LineLayout {
        let attr = NSMutableAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
        let ps = NSMutableParagraphStyle()
        ps.alignment = .center
        ps.lineBreakMode = .byWordWrapping
        attr.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: attr.length))

        let framesetter = CTFramesetterCreateWithAttributedString(attr)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: maxWidth, height: 900),
            nil
        )
        return LineLayout(framesetter: framesetter, size: suggested)
    }

    // MARK: - 时间轴二分

    private func lowerBound(segments: [TimedSegment], startAtLeast t: Double) -> Int {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func upperBound(segments: [TimedSegment], startAtMost t: Double) -> Int {
        var lo = 0
        var hi = segments.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if segments[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    // MARK: - 帧合成

    private func makeFrame(
        segments: [TimedSegment],
        videoTime: Double,
        totalDuration: Double,
        style: CaptionStyle,
        watermark: WatermarkSettings,
        layoutCache: inout [Int: LineLayout],
        pool: CVPixelBufferPool
    ) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                  data: base,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                      | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }

        let fullRect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fill(fullRect)

        // 滚动字幕流
        drawRollingCaptions(
            in: ctx,
            time: videoTime,
            segments: segments,
            layoutCache: &layoutCache,
            style: style,
            canvas: fullRect.size
        )

        // 底部进度条（随分辨率等比缩放）
        if totalDuration > 0 {
            let scale = CGFloat(height) / 1080.0
            let fraction = CGFloat(min(max(videoTime / totalDuration, 0), 1))
            ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.85).cgColor)
            ctx.fill(CGRect(x: 0, y: 22 * scale, width: CGFloat(width) * fraction, height: 6 * scale))
        }

        // 水印
        if watermark.enabled {
            drawWatermark(watermark, in: ctx, canvas: fullRect.size)
        }

        // 调试帧转储：BOOKSTREAM_FRAMEDUMP=/tmp/fd 时每 30 帧（可被 BOOKSTREAM_FRAMEDUMP_EVERY 覆盖）存一张 PNG
        if let dumpDir = Self.frameDumpDir {
            let every = Self.frameDumpEvery
            if Int64(videoTime * Double(fps)) % Int64(every) == 0 {
                dumpFrame(ctx, index: Int64(videoTime * Double(fps)), dir: dumpDir)
            }
        }
        return pixelBuffer
    }

    // MARK: - 水印

    private static let imageCacheLock = NSLock()
    private nonisolated(unsafe) static var watermarkImageCache: [Data: CGImage] = [:]

    private func loadWatermarkImage(_ data: Data) -> CGImage? {
        Self.imageCacheLock.lock()
        defer { Self.imageCacheLock.unlock() }
        if let cached = Self.watermarkImageCache[data] { return cached }
        guard let image = CGImageSourceCreateWithData(data as CFData, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else { return nil }
        Self.watermarkImageCache[data] = image
        return image
    }

    private func drawWatermark(_ wm: WatermarkSettings, in ctx: CGContext, canvas: CGSize) {
        let scale = CGFloat(canvas.height / 1080.0)
        let margin: CGFloat = 26 * scale
        let text = wm.text.isEmpty ? "BookStream" : wm.text

        if let data = wm.imageData, let image = loadWatermarkImage(data) {
            let w = canvas.width * CGFloat(wm.imageScale)
            let h = w * CGFloat(image.height) / CGFloat(image.width)
            let origin = watermarkRectOrigin(size: CGSize(width: w, height: h), position: wm.position, canvas: canvas, margin: margin)
            ctx.saveGState()
            ctx.setAlpha(CGFloat(wm.opacity))
            // 本上下文是非翻转（y 向上、无 CTM 翻转），CGImage 直接 draw 即为正向。
            // 勿用 translateBy+scaleBy(-1)：位图上下文非翻转时追加该翻转会把图片旋转 180°
            // （上下颠倒+左右镜像），与文字 CTFrameDraw 已知的翻转陷阱是同一类问题。
            ctx.draw(image, in: CGRect(x: origin.x, y: origin.y, width: w, height: h))
            ctx.restoreGState()
        } else {
            let font = NSFont.systemFont(ofSize: CGFloat(wm.fontSize) * scale, weight: .regular)
            let attr = NSMutableAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: wm.color.nsColor,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
            let size = CGSize(width: width, height: ascent + descent)
            let x: CGFloat
            switch wm.position {
            case .topLeft, .midLeft, .bottomLeft: x = margin
            case .topCenter, .center, .bottomCenter: x = (canvas.width - size.width) / 2
            case .topRight, .midRight, .bottomRight: x = canvas.width - margin - size.width
            }
            let blockBottom: CGFloat
            switch wm.position {
            case .topLeft, .topCenter, .topRight: blockBottom = canvas.height - margin - size.height
            case .midLeft, .center, .midRight: blockBottom = (canvas.height - size.height) / 2
            case .bottomLeft, .bottomCenter, .bottomRight: blockBottom = margin
            }
            ctx.saveGState()
            ctx.setAlpha(CGFloat(wm.opacity))
            ctx.textPosition = CGPoint(x: x, y: blockBottom + descent)
            CTLineDraw(line, ctx)
            ctx.restoreGState()
        }
    }

    /// 图片水印矩形左下角坐标（y 向上）。
    private func watermarkRectOrigin(size: CGSize, position: WatermarkSettings.Position, canvas: CGSize, margin: CGFloat) -> CGPoint {
        let x: CGFloat
        switch position {
        case .topLeft, .midLeft, .bottomLeft: x = margin
        case .topCenter, .center, .bottomCenter: x = (canvas.width - size.width) / 2
        case .topRight, .midRight, .bottomRight: x = canvas.width - margin - size.width
        }
        let y: CGFloat
        switch position {
        case .topLeft, .topCenter, .topRight: y = canvas.height - margin - size.height
        case .midLeft, .center, .midRight: y = (canvas.height - size.height) / 2
        case .bottomLeft, .bottomCenter, .bottomRight: y = margin
        }
        return CGPoint(x: x, y: y)
    }

    /// 调试：把当前帧像素原样写出为 PNG（不经过任何坐标系变换，供方向性检查）。
    private func dumpFrame(_ ctx: CGContext, index: Int64, dir: String) {
        guard let image = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: dir)
                .appendingPathComponent(String(format: "frame-%04d.png", index)))
        }
        // 原始内存行序（行0=缓冲首行），用于对照 makeImage 是否发生隐式翻转
        if let base = ctx.data {
            let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
            let src = base.assumingMemoryBound(to: UInt8.self)
            let raw = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let dst = raw.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { memcpy(dst + y * w * 4, src + y * bpr, w * 4) }
            let rawRep = NSBitmapImageRep(cgImage: raw.makeImage()!)
            if let png = rawRep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: dir)
                    .appendingPathComponent(String(format: "frame-%04d-raw.png", index)))
            }
        }
    }
}

/// loadTracks 结果容器（线程安全，桥接 async → sync）。
private final class TrackLoadBox: @unchecked Sendable {
    var tracks: [AVAssetTrack] = []
    var error: Error?
}
