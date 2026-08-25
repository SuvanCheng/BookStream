import Foundation
@preconcurrency import AVFoundation
import CoreMedia
import CoreVideo
import CoreGraphics
import CoreText
import AppKit
import Accelerate
import VideoToolbox

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

    // 常用预设
    public static let vividOrange = CaptionColor(red: 1.00, green: 0.55, blue: 0.00)
    public static let white       = CaptionColor(red: 0.95, green: 0.95, blue: 0.95)
    public static let red         = CaptionColor(red: 1.00, green: 0.29, blue: 0.29)
    public static let yellow      = CaptionColor(red: 1.00, green: 0.80, blue: 0.20)
    public static let green       = CaptionColor(red: 0.30, green: 0.90, blue: 0.45)
    public static let cyan        = CaptionColor(red: 0.25, green: 0.85, blue: 0.90)
    public static let blue        = CaptionColor(red: 0.35, green: 0.65, blue: 1.00)
    public static let purple      = CaptionColor(red: 0.80, green: 0.45, blue: 1.00)
    public static let pink        = CaptionColor(red: 1.00, green: 0.45, blue: 0.75)
}

/// 视频画幅比例预设（16:9 横屏、9:16 竖屏短视频、1:1 方形）。
public enum VideoAspectRatio: String, CaseIterable, Codable, Identifiable, Sendable {
    case landscape16_9 = "landscape16_9"
    case portrait9_16  = "portrait9_16"
    case square1_1     = "square1_1"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .landscape16_9: return "16:9 横屏 (通用/B站/YouTube)"
        case .portrait9_16:  return "9:16 竖屏 (短视频/抖音/视频号/Shorts)"
        case .square1_1:     return "1:1 方形 (播客/社媒封面)"
        }
    }
}

/// 视频画质档位。
public enum VideoQuality: String, CaseIterable, Codable, Identifiable, Sendable {
    case p480  = "480p"
    case p720  = "720p"
    case p1080 = "1080p"
    case p4k   = "4K"

    public var id: String { rawValue }
    public var label: String { rawValue }
}

/// 视频编码格式（H.264 / HEVC 硬件加速压缩）。
public enum VideoCodec: String, CaseIterable, Codable, Identifiable, Sendable {
    case h264 = "h264"
    case hevc = "hevc"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .h264: return "H.264 (广泛兼容)"
        case .hevc: return "HEVC / H.265 (硬件加速·体积减半)"
        }
    }

    public var avCodecType: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// 自定义字幕字体预设。
public enum SubtitleFont: String, CaseIterable, Codable, Identifiable, Sendable {
    case systemDefault = "systemDefault"
    case songti        = "Songti SC"
    case kaiti         = "Kaiti SC"
    case pingfang      = "PingFang SC"
    case yuanti        = "Yuanti SC"
    case georgia       = "Georgia"
    case helvetica     = "Helvetica Neue"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .systemDefault: return "系统默认 (黑体)"
        case .songti:        return "经典宋体 (文学/古籍)"
        case .kaiti:         return "优雅楷体 (散文/随笔)"
        case .pingfang:      return "苹方黑体 (现代极简)"
        case .yuanti:        return "圆体 (柔和亲切)"
        case .georgia:       return "Georgia (西文衬线)"
        case .helvetica:     return "Helvetica (西文现代)"
        }
    }
}

/// 视频背景主题预设
public enum BackgroundTheme: String, CaseIterable, Codable, Identifiable, Sendable {
    case pureBlack = "pureBlack"
    case darkGradient = "darkGradient"
    case charcoal = "charcoal"
    case midnightPurple = "midnightPurple"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .pureBlack: return "极简纯黑"
        case .darkGradient: return "深空微光"
        case .charcoal: return "炭黑雅致"
        case .midnightPurple: return "午夜暗韵"
        }
    }
}

/// 滚动字幕排版样式。
public struct CaptionStyle: Sendable {
    public let highlight: CaptionColor
    public let normal: CaptionColor
    public let scrollSpeed: Double // 像素/秒，控制字幕上滚速度
    public let theme: BackgroundTheme
    public let showVisualizer: Bool
    public let font: SubtitleFont
    public let enableKaraoke: Bool

    public init(
        highlight: CaptionColor = .vividOrange,
        normal: CaptionColor = .white,
        scrollSpeed: Double = 55,
        theme: BackgroundTheme = .pureBlack,
        showVisualizer: Bool = true,
        font: SubtitleFont = .systemDefault,
        enableKaraoke: Bool = true
    ) {
        self.highlight = highlight
        self.normal = normal
        self.scrollSpeed = scrollSpeed
        self.theme = theme
        self.showVisualizer = showVisualizer
        self.font = font
        self.enableKaraoke = enableKaraoke
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

/// 视频输出分辨率预设（动态适配 16:9 横屏 / 9:16 竖屏短视频 / 1:1 方形与画质档位）。
public struct VideoResolution: Sendable, Hashable {
    public let width: Int
    public let height: Int
    public let bitrate: Int
    public let label: String
    public let aspectRatio: VideoAspectRatio
    public let quality: VideoQuality

    public init(
        width: Int,
        height: Int,
        bitrate: Int,
        label: String,
        aspectRatio: VideoAspectRatio = .landscape16_9,
        quality: VideoQuality = .p480
    ) {
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.label = label
        self.aspectRatio = aspectRatio
        self.quality = quality
    }

    public static func make(aspectRatio: VideoAspectRatio, quality: VideoQuality) -> VideoResolution {
        switch (aspectRatio, quality) {
        case (.landscape16_9, .p480):
            return VideoResolution(width: 854, height: 480, bitrate: 1_500_000, label: "480p", aspectRatio: aspectRatio, quality: quality)
        case (.landscape16_9, .p720):
            return VideoResolution(width: 1280, height: 720, bitrate: 3_500_000, label: "720p", aspectRatio: aspectRatio, quality: quality)
        case (.landscape16_9, .p1080):
            return VideoResolution(width: 1920, height: 1080, bitrate: 6_000_000, label: "1080p", aspectRatio: aspectRatio, quality: quality)
        case (.landscape16_9, .p4k):
            return VideoResolution(width: 3840, height: 2160, bitrate: 20_000_000, label: "4K", aspectRatio: aspectRatio, quality: quality)

        case (.portrait9_16, .p480):
            return VideoResolution(width: 480, height: 854, bitrate: 1_500_000, label: "480p", aspectRatio: aspectRatio, quality: quality)
        case (.portrait9_16, .p720):
            return VideoResolution(width: 720, height: 1280, bitrate: 3_500_000, label: "720p", aspectRatio: aspectRatio, quality: quality)
        case (.portrait9_16, .p1080):
            return VideoResolution(width: 1080, height: 1920, bitrate: 6_000_000, label: "1080p", aspectRatio: aspectRatio, quality: quality)
        case (.portrait9_16, .p4k):
            return VideoResolution(width: 2160, height: 3840, bitrate: 20_000_000, label: "4K", aspectRatio: aspectRatio, quality: quality)

        case (.square1_1, .p480):
            return VideoResolution(width: 480, height: 480, bitrate: 1_200_000, label: "480p", aspectRatio: aspectRatio, quality: quality)
        case (.square1_1, .p720):
            return VideoResolution(width: 720, height: 720, bitrate: 2_800_000, label: "720p", aspectRatio: aspectRatio, quality: quality)
        case (.square1_1, .p1080):
            return VideoResolution(width: 1080, height: 1080, bitrate: 5_000_000, label: "1080p", aspectRatio: aspectRatio, quality: quality)
        case (.square1_1, .p4k):
            return VideoResolution(width: 2160, height: 2160, bitrate: 16_000_000, label: "4K", aspectRatio: aspectRatio, quality: quality)
        }
    }

    public static let p480  = make(aspectRatio: .landscape16_9, quality: .p480)
    public static let p720  = make(aspectRatio: .landscape16_9, quality: .p720)
    public static let p1080 = make(aspectRatio: .landscape16_9, quality: .p1080)
    public static let p4k   = make(aspectRatio: .landscape16_9, quality: .p4k)

    public static let all: [VideoResolution] = [.p480, .p720, .p1080, .p4k]
}

/// 动态字幕排版视频渲染器。
///
/// 两阶段离线管线：
/// 1. `AVAssetReader` 读取 WAV 音频流推入 `AVAssetWriter` 音频输入（AAC 44.1 kHz 128 kbps）；
/// 2. 按 30 fps 逐帧渲染「从下往上滚动」的字幕流：当前句进入中心高亮区即开始，
///    上方为已淡出的历史字幕，下方为即将到来的字幕（CoreText 排版进 `CVPixelBufferPool`
///    复用的 32BGRA 像素缓冲），推入视频输入（H.264 硬件编码，分辨率/码率可按
///    `VideoResolution` 选择 480p/720p/1080p/4K，默认 480p）。
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
    private var fps: Int32 = 30   // 由 render(fps:) 注入（24/25/30/60），仅渲染线程读写

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
        resolution: VideoResolution = .p480,
        codec: VideoCodec = .h264,
        watermark: WatermarkSettings = .default,
        fps: Int = 30,
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
                        codec: codec,
                        watermark: watermark,
                        fps: fps,
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
        codec: VideoCodec,
        watermark: WatermarkSettings,
        fps: Int,
        progress: @escaping @Sendable @MainActor (Double) -> Void,
        cancellation: @escaping @Sendable () -> Bool
    ) throws {
        // 应用所选分辨率与帧率（供内部帧合成使用）
        self.width = resolution.width
        self.height = resolution.height
        self.fps = Int32(max(1, fps))
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

        // 章节与媒体描述元数据（YouTube / B站 / 播放器识别选章）
        let sortedSegments = segments.sorted { $0.startFrame < $1.startFrame }
        let chapters = TextProcessor.detectChapters(segments: sortedSegments)
        if !chapters.isEmpty {
            var chapterList = ""
            for ch in chapters {
                chapterList += "\(ChapterWriter.formatTimestamp(ch.start)) \(ch.title)\n"
            }
            let descItem = AVMutableMetadataItem()
            descItem.keySpace = .common
            descItem.key = AVMetadataKey.commonKeyDescription as NSString
            descItem.value = chapterList.trimmingCharacters(in: .whitespacesAndNewlines) as NSString

            let infoItem = AVMutableMetadataItem()
            infoItem.keySpace = .quickTimeUserData
            infoItem.key = AVMetadataKey.quickTimeUserDataKeyInformation as NSString
            infoItem.value = chapterList.trimmingCharacters(in: .whitespacesAndNewlines) as NSString

            writer.metadata = [descItem, infoItem]
        }

        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000,
        ])
        audioInput.expectsMediaDataInRealTime = false

        var compressionProps: [String: Any] = [
            AVVideoAverageBitRateKey: resolution.bitrate,
            AVVideoMaxKeyFrameIntervalKey: 60,
            AVVideoAllowFrameReorderingKey: false,
        ]
        if codec == .hevc {
            compressionProps[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel
        } else {
            compressionProps[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec.avCodecType,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compressionProps,
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

        // ---- 3. 像素缓冲池 ----
        guard let pool = adaptor.pixelBufferPool else {
            throw BookStreamError.videoRenderFailed("无法获取像素缓冲池")
        }

        // ---- 4. 全局排版预热（全量并发排版，主渲染循环 100% 命中无锁表）----
        let scale = min(CGFloat(width), CGFloat(height)) / 1080.0
        let maxWidth = CGFloat(width) - (width < height ? 80 : 200) * scale
        let speed = CGFloat(style.scrollSpeed) * scale
        let halfWindow: CGFloat = CGFloat(height) * 0.55
        let rangeSeconds = Double(halfWindow) / Double(max(speed, 1))
        let minGap: CGFloat = 22 * scale
        let layouts = precomputeLayouts(segments: sortedSegments, style: style, scale: scale, maxWidth: maxWidth)
        let audioSpectrum = style.showVisualizer ? Self.extractAudioSpectrum(from: audioURL) : []
        let spectrumBox = UncheckedSendableBox(audioSpectrum)

        // ---- 5. 主循环：多核并发批渲染流水线 + 单队列按序推送音视频 ----
        var videoIndex: Int64 = 0
        var pendingAudio: CMSampleBuffer?
        var audioDone = false
        var audioFinished = false
        let batchSize = 16
        let poolBox = UncheckedSendableBox(pool)

        // 进度看门狗
        var lastProgress = Date()
        var audioAppendedCount: Int64 = 0

        while videoIndex < totalVideoFrames || pendingAudio != nil || !audioDone {
            if cancellation() { throw BookStreamError.cancelled }

            let currentVideoTime = Double(videoIndex) / Double(fps)

            // 1. 音频推进：按视频时间对齐（最多超前视频 2.0 秒），避免音频暴冲导致 AVAssetWriter 复用器背压死锁
            while !audioDone {
                if pendingAudio == nil {
                    if let buf = readerOutput.copyNextSampleBuffer() {
                        pendingAudio = buf
                    } else {
                        audioDone = true
                        break
                    }
                }

                guard let buf = pendingAudio else { break }
                let audioTime = buf.presentationTimeStamp.seconds
                if audioTime > currentVideoTime + 2.0 && videoIndex < totalVideoFrames {
                    // 音频已超前视频 2 秒，等待视频渲染推进
                    break
                }

                if audioInput.isReadyForMoreMediaData {
                    if audioInput.append(buf) {
                        pendingAudio = nil
                        audioAppendedCount += 1
                        lastProgress = Date()
                    } else {
                        break
                    }
                } else {
                    break
                }
            }

            if !audioFinished && audioDone && pendingAudio == nil {
                audioInput.markAsFinished()
                audioFinished = true
            }

            // 2. 视频推进：以 16 帧为批次多核并行渲染并推送到写入器
            if videoIndex < totalVideoFrames {
                let framesToRender = Int(min(Int64(batchSize), totalVideoFrames - videoIndex))
                let batchBuffers = ConcurrentBufferBox<CVPixelBuffer>(count: framesToRender)
                let baseIndex = videoIndex

                // 多核并行渲染该批次的所有视频帧
                DispatchQueue.concurrentPerform(iterations: framesToRender) { idx in
                    autoreleasepool {
                        let frameIdx = baseIndex + Int64(idx)
                        let videoTime = Double(frameIdx) / Double(fps)
                        batchBuffers[idx] = makeFrame(
                            segments: sortedSegments,
                            videoTime: videoTime,
                            totalDuration: totalDuration,
                            style: style,
                            watermark: watermark,
                            layouts: layouts,
                            spectrum: spectrumBox.value,
                            scale: scale,
                            maxWidth: maxWidth,
                            minGap: minGap,
                            speed: speed,
                            halfWindow: halfWindow,
                            rangeSeconds: rangeSeconds,
                            pool: poolBox.value
                        )
                    }
                }

                // 严格按 PTS 顺序将该批次像素缓冲推给写入器
                for idx in 0..<framesToRender {
                    if cancellation() { throw BookStreamError.cancelled }
                    guard let pixelBuffer = batchBuffers[idx] else {
                        throw BookStreamError.videoRenderFailed("像素缓冲生成失败（帧 \(baseIndex + Int64(idx))）")
                    }

                    // 等待视频输入端就绪（等待期间同步排空音频）
                    while !videoInput.isReadyForMoreMediaData {
                        if cancellation() { throw BookStreamError.cancelled }
                        if let buf = pendingAudio, audioInput.isReadyForMoreMediaData {
                            if audioInput.append(buf) {
                                pendingAudio = nil
                                audioAppendedCount += 1
                                lastProgress = Date()
                            }
                        }
                        if Date().timeIntervalSince(lastProgress) > 60 {
                            throw BookStreamError.videoRenderFailed(
                                "编码写入停滞（帧 \(baseIndex + Int64(idx))/\(totalVideoFrames)）"
                            )
                        }
                        Thread.sleep(forTimeInterval: 0.002)
                    }

                    let pts = CMTime(value: baseIndex + Int64(idx), timescale: self.fps)
                    guard adaptor.append(pixelBuffer, withPresentationTime: pts) else {
                        throw BookStreamError.videoRenderFailed("追加视频帧失败（帧 \(baseIndex + Int64(idx))）")
                    }
                }

                videoIndex += Int64(framesToRender)
                lastProgress = Date()

                if videoIndex % 30 == 0 || videoIndex >= totalVideoFrames {
                    let p = Double(videoIndex) / Double(max(totalVideoFrames, 1))
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { progress(p) }
                    }
                }
            } else if !audioDone || pendingAudio != nil {
                // 视频已写完，让出等待音频完成
                Thread.sleep(forTimeInterval: 0.005)
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

    // MARK: - 并发缓冲容器

    private final class UncheckedSendableBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    private final class ConcurrentBufferBox<T>: @unchecked Sendable {
        let pointer: UnsafeMutablePointer<T?>
        let count: Int
        init(count: Int) {
            self.count = count
            self.pointer = .allocate(capacity: count)
            self.pointer.initialize(repeating: nil, count: count)
        }
        deinit {
            self.pointer.deinitialize(count: count)
            self.pointer.deallocate()
        }
        subscript(index: Int) -> T? {
            get { pointer[index] }
            set { pointer[index] = newValue }
        }
    }

    // MARK: - 滚动字幕渲染

    /// 缓存的单行预排版只读图像（immutable CGImage，多线程绝对并发安全，0 锁 0 竞争 0 闪烁）。
    private struct SubLineInfo: @unchecked Sendable {
        let rect: CGRect
        let startChar: Int
        let endChar: Int
        var charCount: Int { max(1, endChar - startChar) }
    }

    private struct LineLayout: @unchecked Sendable {
        let image: CGImage
        let size: CGSize
        let lines: [SubLineInfo]
        let totalChars: Int
    }

    private static func makeFont(named fontChoice: SubtitleFont, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        switch fontChoice {
        case .systemDefault:
            return NSFont.systemFont(ofSize: size, weight: weight)
        case .songti:
            return NSFont(name: "Songti SC", size: size) ?? NSFont(name: "STSong", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .kaiti:
            return NSFont(name: "Kaiti SC", size: size) ?? NSFont(name: "STKaiti", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .pingfang:
            return NSFont(name: "PingFang SC", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .yuanti:
            return NSFont(name: "Yuanti SC", size: size) ?? NSFont(name: "STYuanti-SC-Regular", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .georgia:
            return NSFont(name: "Georgia", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        case .helvetica:
            return NSFont(name: "Helvetica Neue", size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
        }
    }

    /// 并发预计算所有字幕行的三种排版（普通 / 居中底色 / 居中高亮），生成只读排版表。
    private func precomputeLayouts(
        segments: [TimedSegment],
        style: CaptionStyle,
        scale: CGFloat,
        maxWidth: CGFloat
    ) -> [LineLayout] {
        let fontHighlight = Self.makeFont(named: style.font, size: 72 * scale, weight: .bold)
        let fontNormal = Self.makeFont(named: style.font, size: 44 * scale, weight: .regular)
        let fontHighlightBox = UncheckedSendableBox(fontHighlight)
        let fontNormalBox = UncheckedSendableBox(fontNormal)
        let colorHighlightBox = UncheckedSendableBox(style.highlight.nsColor)
        let colorNormalBox = UncheckedSendableBox(style.normal.nsColor)

        // 生成 3 种排版：
        // 0: 普通字号（44pt）
        // 1: 居中当前句底色（72pt，白/微透色）
        // 2: 居中当前句高亮色（72pt，highlightColor）
        let box = ConcurrentBufferBox<LineLayout>(count: segments.count * 3)
        DispatchQueue.concurrentPerform(iterations: segments.count) { i in
            let text = segments[i].text
            let norm = makeLineLayout(text: text, font: fontNormalBox.value, color: colorNormalBox.value, maxWidth: maxWidth)
            let baseCurrent = makeLineLayout(text: text, font: fontHighlightBox.value, color: colorNormalBox.value.withAlphaComponent(0.85), maxWidth: maxWidth)
            let highCurrent = makeLineLayout(text: text, font: fontHighlightBox.value, color: colorHighlightBox.value, maxWidth: maxWidth)
            box[i * 3 + 0] = norm
            box[i * 3 + 1] = baseCurrent
            box[i * 3 + 2] = highCurrent
        }
        var results: [LineLayout] = []
        results.reserveCapacity(segments.count * 3)
        for i in 0..<(segments.count * 3) {
            results.append(box[i]!)
        }
        return results
    }

    /// 从下往上滚动字幕流（恒定速度、当前句锚定中心，无重叠）：
    /// - 当前句固定画面中心（高亮 + 72pt 粗体），整句朗读期间静止，观感稳定丝滑；
    /// - 已结束历史句以固定速度上滚并淡出；未开始未来句以同速接近、线性滚动；
    /// - 所有行按「行高均值 + 间隙」间距约束，杜绝重叠；
    /// - 支持字级卡拉OK点亮动效，随朗读实时向右点亮字词。
    @discardableResult
    private func drawRollingCaptions(
        in ctx: CGContext,
        time: Double,
        segments: [TimedSegment],
        layouts: [LineLayout],
        style: CaptionStyle,
        scale: CGFloat,
        maxWidth: CGFloat,
        minGap: CGFloat,
        speed: CGFloat,
        halfWindow: CGFloat,
        rangeSeconds: Double,
        canvas: CGSize
    ) -> Bool {
        guard !segments.isEmpty else { return false }
        let centerY = canvas.height / 2

        // ---- 1. 判定当前句（二分定位）----
        let cand = upperBound(segments: segments, startAtMost: time) - 1
        let currentIdx: Int?
        if cand >= 0 && cand < segments.count && time >= segments[cand].start && time < segments[cand].end {
            currentIdx = cand
        } else {
            currentIdx = nil
        }

        let rawLo = lowerBound(segments: segments, startAtLeast: time - rangeSeconds)
        let rawHi = upperBound(segments: segments, startAtMost: time + rangeSeconds)
        let lo = min(rawLo, currentIdx ?? rawLo)
        let hi = max(rawHi, (currentIdx.map { $0 + 1 }) ?? rawHi)
        guard lo < hi else { return currentIdx != nil }

        // ---- 2. 获取各句行高（O(1) 预热排版表读取）----
        var heights = [CGFloat](repeating: 0, count: hi - lo)
        for i in lo..<hi {
            let isCurrent = (i == currentIdx)
            let layout = layouts[i * 3 + (isCurrent ? 2 : 0)]
            heights[i - lo] = layout.size.height
        }

        func spacing(_ a: Int, _ b: Int) -> CGFloat {
            (heights[a - lo] + heights[b - lo]) / 2 + minGap
        }

        // ---- 3. 定位（坐标系：y 向上为正，y=0 底边、y=H 顶边；当前句支持切句缓动）----
        var yCenter = [CGFloat?](repeating: nil, count: hi - lo)

        if let ci = currentIdx {
            let seg = segments[ci]
            let dt = time - seg.start
            let easeDuration = 0.32
            let targetY = centerY
            let rawY = centerY - CGFloat(seg.start - time) * speed
            let anchorY: CGFloat
            if dt < easeDuration && dt >= 0 {
                let u = CGFloat(dt / easeDuration)
                let ease = 1.0 - (1.0 - u) * (1.0 - u) * (1.0 - u) // cubic ease-out
                anchorY = rawY + (targetY - rawY) * ease
            } else {
                anchorY = targetY
            }
            yCenter[ci - lo] = anchorY

            // 历史（上方，y 更大）：从当前句向上约束
            if ci > lo {
                for i in stride(from: ci - 1, through: lo, by: -1) {
                    let raw = anchorY + CGFloat(time - segments[i].end) * speed
                    yCenter[i - lo] = max(raw, yCenter[i + 1 - lo]! + spacing(i, i + 1))
                }
            }
            // 未来（下方，y 更小）：从当前句向下约束
            if ci + 1 < hi {
                for i in (ci + 1)..<hi {
                    let raw = anchorY - CGFloat(segments[i].start - time) * speed
                    yCenter[i - lo] = min(raw, yCenter[i - 1 - lo]! - spacing(i - 1, i))
                }
            }
        } else {
            // 无当前句（间隙）：以「下一句」为锚点（不钉在中心，仅用于约束）
            let nxt = upperBound(segments: segments, startAtMost: time)
            if nxt >= hi {
                // 全部为历史：从中心向上堆叠
                for i in stride(from: hi - 1, through: lo, by: -1) {
                    let raw = centerY + CGFloat(time - segments[i].end) * speed
                    yCenter[i - lo] = (i + 1 < hi) ? max(raw, yCenter[i + 1 - lo]! + spacing(i, i + 1)) : raw
                }
            } else if nxt <= lo {
                // 全部为未来：向中心上移接近
                for i in lo..<hi {
                    let raw = centerY - CGFloat(segments[i].start - time) * speed
                    yCenter[i - lo] = (i > lo) ? min(raw, yCenter[i - 1 - lo]! - spacing(i - 1, i)) : raw
                }
            } else {
                // 锚点下一句在窗口内
                yCenter[nxt - lo] = centerY - CGFloat(segments[nxt].start - time) * speed
                if nxt > lo {
                    for i in stride(from: nxt - 1, through: lo, by: -1) {
                        let raw = centerY + CGFloat(time - segments[i].end) * speed
                        yCenter[i - lo] = max(raw, yCenter[i + 1 - lo]! + spacing(i, i + 1))
                    }
                }
                if nxt + 1 < hi {
                    for i in (nxt + 1)..<hi {
                        let raw = centerY - CGFloat(segments[i].start - time) * speed
                        yCenter[i - lo] = min(raw, yCenter[i - 1 - lo]! - spacing(i - 1, i))
                    }
                }
            }
        }

        // ---- 4. 直接绘制 ----
        func drawLine(_ i: Int, isCurrent: Bool) {
            let seg = segments[i]
            guard let y = yCenter[i - lo] else { return }
            guard y > -320 * scale, y < canvas.height + 320 * scale else { return }

            if isCurrent {
                let baseLayout = layouts[i * 3 + 1]
                let highLayout = layouts[i * 3 + 2]
                let w = CGFloat(highLayout.image.width)
                let h = CGFloat(highLayout.image.height)
                let roundedX = round((canvas.width - w) / 2)
                let roundedY = round(y - h / 2)
                let rect = CGRect(x: roundedX, y: roundedY, width: w, height: h)

                ctx.setAlpha(1.0)
                if style.enableKaraoke {
                    // 1. 先绘制底色字形
                    ctx.draw(baseLayout.image, in: rect)

                    // 2. 逐行·字符级卡拉OK点亮动效（以语音实际发音时长为基准，精准消除句尾停顿导致的滞后）
                    let p = min(1.0, max(0.0, (time - seg.start) / seg.speechDuration))
                    let totalChars = max(1, highLayout.totalChars)
                    let activeChar = p * Double(totalChars)

                    let clipPath = CGMutablePath()
                    for line in highLayout.lines {
                        let lineClipW: CGFloat
                        if activeChar <= Double(line.startChar) {
                            lineClipW = 0
                        } else if activeChar >= Double(line.endChar) {
                            lineClipW = line.rect.width
                        } else {
                            let pLine = (activeChar - Double(line.startChar)) / Double(max(1, line.charCount))
                            lineClipW = line.rect.width * CGFloat(pLine)
                        }
                        if lineClipW > 0 {
                            let lineRect = CGRect(
                                x: roundedX + line.rect.minX,
                                y: roundedY + line.rect.minY,
                                width: lineClipW,
                                height: line.rect.height
                            )
                            clipPath.addRect(lineRect)
                        }
                    }

                    if !clipPath.isEmpty {
                        ctx.saveGState()
                        ctx.addPath(clipPath)
                        ctx.clip()
                        ctx.draw(highLayout.image, in: rect)
                        ctx.restoreGState()
                    }
                } else {
                    ctx.draw(highLayout.image, in: rect)
                }
            } else {
                let layout = layouts[i * 3 + 0]
                let alpha: CGFloat
                if time < seg.start {
                    let remaining = CGFloat(seg.start - time)
                    alpha = min(1.0, max(0.35, 1.0 - remaining / 3.0 * 0.65))
                } else {
                    let age = CGFloat(time - seg.end)
                    alpha = max(0.30, 1.0 - age / 5.0 * 0.70)
                }

                let w = CGFloat(layout.image.width)
                let h = CGFloat(layout.image.height)
                let roundedX = round((canvas.width - w) / 2)
                let roundedY = round(y - h / 2)
                let rect = CGRect(x: roundedX, y: roundedY, width: w, height: h)

                ctx.setAlpha(alpha)
                ctx.draw(layout.image, in: rect)
            }
        }

        for i in lo..<hi where i != currentIdx {
            drawLine(i, isCurrent: false)
        }
        if let ci = currentIdx {
            drawLine(ci, isCurrent: true)
        }

        return currentIdx != nil
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
        let w = max(1, Int(ceil(suggested.width)))
        let h = max(1, Int(ceil(suggested.height)))
        let ctx = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )
        if let ctx {
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            ctx.setAllowsFontSmoothing(false) // 禁用 LCD 亚像素彩色边缘，确保纯净灰度抗锯齿，杜绝 YUV 压缩下的字母边缘闪烁
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(true)
            ctx.setShouldSubpixelPositionFonts(true)
            ctx.setAllowsFontSubpixelQuantization(true)
            ctx.setShouldSubpixelQuantizeFonts(true)

            let path = CGPath(rect: CGRect(x: 0, y: 0, width: w, height: h), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
            CTFrameDraw(frame, ctx)

            let ctLines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: ctLines.count)
            CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)

            var subLines: [SubLineInfo] = []
            var totalChars = 0
            for (i, line) in ctLines.enumerated() {
                let range = CTLineGetStringRange(line)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let lineWidth = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
                let lineX = origins[i].x
                let lineY = origins[i].y - descent
                let lineH = ascent + descent
                let lineRect = CGRect(x: lineX, y: lineY, width: lineWidth, height: lineH)
                subLines.append(SubLineInfo(rect: lineRect, startChar: range.location, endChar: range.location + range.length))
                totalChars = max(totalChars, range.location + range.length)
            }

            if let img = ctx.makeImage() {
                return LineLayout(
                    image: img,
                    size: CGSize(width: CGFloat(w), height: CGFloat(h)),
                    lines: subLines,
                    totalChars: max(1, totalChars)
                )
            }
        }
        // 回退保障（极端空 context）
        let fallbackCtx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        return LineLayout(image: fallbackCtx.makeImage()!, size: .zero, lines: [], totalChars: 1)
    }

    // MARK: - 主题背景与声波可视化绘制

    /// 绘制多样化背景主题（纯黑、深空微光渐变、炭黑雅致、午夜暗韵）。
    private func drawBackground(theme: BackgroundTheme, in ctx: CGContext, canvas: CGSize) {
        let fullRect = CGRect(origin: .zero, size: canvas)
        switch theme {
        case .pureBlack:
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(fullRect)

        case .darkGradient:
            // 深邃墨蓝 -> 纯黑
            let colors = [
                NSColor(calibratedRed: 0.05, green: 0.08, blue: 0.16, alpha: 1.0).cgColor,
                NSColor(calibratedRed: 0.01, green: 0.02, blue: 0.04, alpha: 1.0).cgColor,
                NSColor.black.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.45, 1.0]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: canvas.width / 2, y: canvas.height), end: CGPoint(x: canvas.width / 2, y: 0), options: [])
            } else {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(fullRect)
            }

        case .charcoal:
            // 炭黑暖调
            let colors = [
                NSColor(calibratedRed: 0.11, green: 0.11, blue: 0.12, alpha: 1.0).cgColor,
                NSColor(calibratedRed: 0.04, green: 0.04, blue: 0.05, alpha: 1.0).cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 1.0]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: canvas.width / 2, y: canvas.height), end: CGPoint(x: canvas.width / 2, y: 0), options: [])
            } else {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(fullRect)
            }

        case .midnightPurple:
            // 午夜暗紫 -> 纯黑
            let colors = [
                NSColor(calibratedRed: 0.09, green: 0.05, blue: 0.14, alpha: 1.0).cgColor,
                NSColor(calibratedRed: 0.02, green: 0.01, blue: 0.04, alpha: 1.0).cgColor,
                NSColor.black.cgColor
            ] as CFArray
            let locations: [CGFloat] = [0.0, 0.5, 1.0]
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: locations) {
                ctx.drawLinearGradient(grad, start: CGPoint(x: canvas.width / 2, y: canvas.height), end: CGPoint(x: canvas.width / 2, y: 0), options: [])
            } else {
                ctx.setFillColor(NSColor.black.cgColor)
                ctx.fill(fullRect)
            }
        }
    }

    // MARK: - 音频多频段频谱提取

    /// 快速从音频文件提取 60Hz 采样精度的 36 频段对数 FFT 频谱（Accelerate 硬件加速，全书仅耗时 ~0.3s）。
    /// 包含快速起振（Attack）与平滑重力回落（Decay）动力学，真实呈现低/中/高频的丰富层次与呼吸感。
    private static func extractAudioSpectrum(from url: URL) -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { return [] }
        let format = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return [] }
        let sampleRate = Float(format.sampleRate)

        let fftSize = 1024
        let log2n = vDSP_Length(log2(Float(fftSize)))
        guard let fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(fftSetup) }

        let fps: Float = 60.0
        let hopSize = max(1, Int(sampleRate / fps))
        let numFrames = Int(totalFrames) / hopSize
        guard numFrames > 0 else { return [] }
        let barCount = 36

        // 36 频段按人耳听觉对数分布（85 Hz ~ 7500 Hz）
        let minFreq: Float = 85.0
        let maxFreq: Float = 7500.0
        var bandBins = [Int](repeating: 0, count: barCount)
        for i in 0..<barCount {
            let t = Float(i) / Float(barCount - 1)
            let freq = minFreq * pow(maxFreq / minFreq, t)
            let bin = Int(round(freq * Float(fftSize) / sampleRate))
            bandBins[i] = max(1, min(fftSize / 2 - 1, bin))
        }

        var spectrum = [Float](repeating: 0, count: numFrames * barCount)

        guard let fullBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: totalFrames) else { return [] }
        guard (try? file.read(into: fullBuffer, frameCount: totalFrames)) != nil,
              let fullChannel = fullBuffer.floatChannelData?[0] else { return [] }

        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var realBuffer = [Float](repeating: 0, count: fftSize / 2)
        var imagBuffer = [Float](repeating: 0, count: fftSize / 2)
        var windowed = [Float](repeating: 0, count: fftSize)
        var magnitudes = [Float](repeating: 0, count: fftSize / 2)
        var smoothed = [Float](repeating: 0, count: barCount)

        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var splitComplex = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)

                for f in 0..<numFrames {
                    let offset = f * hopSize
                    if offset + fftSize > Int(totalFrames) { break }

                    vDSP_vmul(fullChannel + offset, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

                    windowed.withUnsafeBufferPointer { winPtr in
                        winPtr.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: fftSize / 2) { complexPtr in
                            vDSP_ctoz(complexPtr, 2, &splitComplex, 1, vDSP_Length(fftSize / 2))
                        }
                    }

                    vDSP_fft_zrip(fftSetup, &splitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                    vDSP_zvabs(&splitComplex, 1, &magnitudes, 1, vDSP_Length(fftSize / 2))

                    var totalPower: Float = 0
                    vDSP_sve(magnitudes, 1, &totalPower, vDSP_Length(fftSize / 2))
                    let isSilent = totalPower < 0.6

                    for b in 0..<barCount {
                        let bin = bandBins[b]
                        let mag = isSilent ? 0 : magnitudes[bin] * (1.0 + Float(b) * 0.08)
                        let target = isSilent ? 0 : min(1.0, mag / 22.0)

                        if target > smoothed[b] {
                            smoothed[b] = smoothed[b] * 0.35 + target * 0.65 // 快速起振
                        } else {
                            smoothed[b] = smoothed[b] * 0.78 + target * 0.22 // 平滑重力回落
                        }
                        if isSilent && smoothed[b] < 0.02 { smoothed[b] = 0 }

                        spectrum[f * barCount + b] = smoothed[b]
                    }
                }
            }
        }

        return spectrum
    }

    /// 绘制真实多频段对数 FFT 频谱驱动的动态声波可视化挂件（36 根胶囊频谱柱，层次分明、起伏平滑灵动，精致不突兀，静止时完全平息）。
    private func drawAudioVisualizer(
        in ctx: CGContext,
        time: Double,
        spectrum: [Float],
        highlightColor: NSColor,
        scale: CGFloat,
        canvas: CGSize
    ) {
        let barCount = 36
        let totalWidth: CGFloat = min(canvas.width - 40, 240 * scale)
        let barWidth: CGFloat = max(1.5, 2.8 * scale)
        let barGap = max(1.0, (totalWidth - CGFloat(barCount) * barWidth) / CGFloat(barCount - 1))
        let startX = (canvas.width - (CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * barGap)) / 2
        let baseY: CGFloat = 34 * scale
        let maxBarHeight: CGFloat = 16 * scale
        let minBarHeight: CGFloat = 2.2 * scale

        let frameIdx = min(max(0, Int(time * 60.0)), max(0, spectrum.count / barCount - 1))
        let frameOffset = frameIdx * barCount

        // 检验本帧是否处于全频段静音
        var isFrameSilent = true
        if !spectrum.isEmpty {
            for b in 0..<barCount {
                if spectrum[frameOffset + b] > 0.015 {
                    isFrameSilent = false
                    break
                }
            }
        }

        for i in 0..<barCount {
            let x = startX + CGFloat(i) * (barWidth + barGap)
            let normIdx = Double(i) / Double(barCount - 1) // 0 to 1
            // 边缘平缓微过渡（避免过陡的椭圆橄榄球感，保留自然频谱跳动）
            let edgeTaper = CGFloat(0.75 + 0.25 * sin(normIdx * .pi))

            // 频段对称映射：低频（人声基频）位于中心附近，高频（泛音/辅音）分布于两侧
            let center = Double(barCount - 1) / 2.0
            let distFromCenter = abs(Double(i) - center) / center // 0 at center, 1 at edge
            let bandIndex = min(barCount - 1, max(0, Int(distFromCenter * Double(barCount - 1))))

            let bandEnergy: CGFloat
            if !spectrum.isEmpty && !isFrameSilent {
                let rawVal = CGFloat(spectrum[frameOffset + bandIndex])
                bandEnergy = pow(rawVal, 0.9)
            } else {
                bandEnergy = 0
            }

            let h: CGFloat
            if !isFrameSilent && bandEnergy > 0.005 {
                let dynamicH = min(1.0, bandEnergy * edgeTaper)
                h = minBarHeight + dynamicH * (maxBarHeight - minBarHeight)
            } else {
                h = minBarHeight
            }

            let rect = CGRect(x: x, y: baseY - h / 2, width: barWidth, height: h)
            let alpha: CGFloat = !isFrameSilent ? (0.30 + bandEnergy * 0.60) : 0.16
            ctx.setFillColor(highlightColor.withAlphaComponent(alpha).cgColor)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            ctx.addPath(path)
            ctx.fillPath()
        }
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
        layouts: [LineLayout],
        spectrum: [Float],
        scale: CGFloat,
        maxWidth: CGFloat,
        minGap: CGFloat,
        speed: CGFloat,
        halfWindow: CGFloat,
        rangeSeconds: Double,
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

        // 1. 背景绘制（支持纯黑、深空微光渐变、炭黑雅致、午夜暗韵）
        drawBackground(theme: style.theme, in: ctx, canvas: fullRect.size)

        // 2. 滚动字幕流（含字级卡拉OK点亮动效与切句平滑缓动）
        _ = drawRollingCaptions(
            in: ctx,
            time: videoTime,
            segments: segments,
            layouts: layouts,
            style: style,
            scale: scale,
            maxWidth: maxWidth,
            minGap: minGap,
            speed: speed,
            halfWindow: halfWindow,
            rangeSeconds: rangeSeconds,
            canvas: fullRect.size
        )

        // 3. 动态声波可视化挂件（置于底部进度条上方，讲话时声律跳动，静止时完全平稳收拢）
        if style.showVisualizer {
            drawAudioVisualizer(
                in: ctx,
                time: videoTime,
                spectrum: spectrum,
                highlightColor: style.highlight.nsColor,
                scale: scale,
                canvas: fullRect.size
            )
        }

        // 4. 底部进度条（随分辨率等比缩放，采用主题高亮色）
        if totalDuration > 0 {
            let fraction = CGFloat(min(max(videoTime / totalDuration, 0), 1))
            ctx.setFillColor(style.highlight.nsColor.withAlphaComponent(0.75).cgColor)
            ctx.fill(CGRect(x: 0, y: 14 * scale, width: CGFloat(width) * fraction, height: 4 * scale))
        }

        // 5. 水印
        if watermark.enabled {
            drawWatermark(watermark, in: ctx, canvas: fullRect.size)
        }

        // 调试帧转储：BOOKSTREAM_FRAMEDUMP=/tmp/fd 时每 30 帧存一张 PNG
        if let dumpDir = Self.frameDumpDir {
            let every = Self.frameDumpEvery
            let frameIdx = Int64(round(videoTime * Double(fps)))
            if frameIdx % Int64(every) == 0 {
                dumpFrame(ctx, index: frameIdx, dir: dumpDir)
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
