import Foundation
import AVFoundation
import AppKit
import Darwin

/// 无头端到端自检（`swift run BookStream --selftest`）：
/// TTS 抓轨 → WAV + SRT → 1080p MP4 视频渲染，全部走真实管线，不依赖 GUI。
enum SelfTest {

    static func run() async {
        // 无缓冲输出：便于观察各阶段实时进度（重定向到文件时也能看到）
        setvbuf(stdout, nil, _IONBF, 0)
        if let idx = CommandLine.arguments.firstIndex(of: "--readframe"), idx + 1 < CommandLine.arguments.count {
            await readFrame(URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
            return
        }
        if let idx = CommandLine.arguments.firstIndex(of: "--parse"), idx + 1 < CommandLine.arguments.count {
            await runParse(URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
            return
        }
        await runSelfTest()
    }

    /// 调试：用 AVAssetReader（与渲染器同路径）提取视频帧保存为 PNG，
    /// 并打印视频轨道 preferredTransform（--readframe <mp4>）。
    private static func readFrame(_ url: URL) async {
        do {
            let asset = AVURLAsset(url: url)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                print("READFRAME FAILED: 无视频轨道"); exit(1)
            }
            let transform = try await track.load(.preferredTransform)
            print("preferredTransform: [\(transform.a),\(transform.b),\(transform.c),\(transform.d),\(transform.tx),\(transform.ty)]")

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            ])
            reader.add(output)
            guard reader.startReading() else { print("READFRAME FAILED: reader"); exit(1) }

            // 取 PTS≈0.5s 的帧
            var picked: CVPixelBuffer?
            while let sb = output.copyNextSampleBuffer() {
                let t = sb.presentationTimeStamp.seconds
                if t >= 0.45 { picked = sb.imageBuffer; break }
            }
            guard let pb = picked else { print("READFRAME FAILED: 无帧"); exit(1) }
            CVPixelBufferLockBaseAddress(pb, [])
            defer { CVPixelBufferUnlockBaseAddress(pb, []) }
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            let bpr = CVPixelBufferGetBytesPerRow(pb)
            let base = CVPixelBufferGetBaseAddress(pb)!.assumingMemoryBound(to: UInt8.self)
            // 按内存行序原样拷贝到 CG 位图并写 PNG（行0=内存首行，无任何变换）
            let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            let dst = ctx.data!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h { memcpy(dst + y * w * 4, base + y * bpr, w * 4) }
            let img = ctx.makeImage()!
            let rep = NSBitmapImageRep(cgImage: img)
            let out = url.deletingPathExtension().appendingPathExtension("frame.png")
            try rep.representation(using: .png, properties: [:])!.write(to: out)
            print("FRAME OK: \(out.path) (\(w)x\(h))")
            reader.cancelReading()
        } catch {
            print("READFRAME FAILED: \(error)")
        }
        exit(0)
    }

    /// 解析校验：swift run BookStream --parse <file>
    private static func runParse(_ url: URL) async {
        do {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "txt", "epub":
                let sentences = try TextProcessor.parseBookFile(url: url)
                let chars = sentences.reduce(0) { $0 + $1.text.count }
                print("PARSE OK [\(ext)]: \(sentences.count) 句, \(chars) 字")
                print("  first: \(sentences.first?.text.prefix(80) ?? "")")
            case "srt":
                let entries = try SrtParser.parse(url: url)
                print("PARSE OK [srt]: \(entries.count) 条, 总时长 \(String(format: "%.2f", entries.last?.end ?? 0))s")
                print("  first: \(entries.first.map { "\($0.start)-\($0.end) \($0.text.prefix(60))" } ?? "")")
            case "ass", "ssa":
                let entries = try AssParser.parse(url: url)
                print("PARSE OK [\(ext)]: \(entries.count) 条, 总时长 \(String(format: "%.2f", entries.last?.end ?? 0))s")
                print("  first: \(entries.first.map { "\($0.start)-\($0.end) \($0.text.prefix(60))" } ?? "")")
            default:
                throw BookStreamError.unsupportedFile(ext)
            }
            exit(0)
        } catch {
            print("PARSE FAILED: \(error)")
            exit(1)
        }
    }

    private static func runSelfTest() async {
        let keepOutputs = CommandLine.arguments.contains("--keep")
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("BookStreamSelfTest-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if keepOutputs {
                print("SELFTEST 输出目录: \(dir.path)")
            }
            // 注意：defer 必须注册在 do 作用域，否则会在 if 块结束时立即执行
            defer {
                if !keepOutputs { try? fm.removeItem(at: dir) }
            }

            let sentences = [
                "Hello, this is the BookStream self test.",
                "The quick brown fox jumps over the lazy dog.",
                "Offline speech synthesis and video rendering work correctly."
            ]

            // 1) TTS 离线抓轨 → WAV + 时间轴
            let engine = AudioEngine()
            let wavURL = dir.appendingPathComponent("selftest.wav")
            let audioProgress: @Sendable @MainActor (Int, Int) -> Void = { _, _ in }
            let cancelled: @Sendable () -> Bool = { false }

            let result = try await engine.renderBook(
                sentences: sentences,
                outputURL: wavURL,
                voiceIdentifier: nil,
                rate: 0.5,
                progress: audioProgress,
                cancellation: cancelled
            )
            guard result.segments.count == sentences.count else {
                throw BookStreamError.audioRenderFailed("片段数不符: \(result.segments.count)")
            }
            let totalDuration = result.segments.last?.end ?? 0
            let wavSize = (try? fm.attributesOfItem(atPath: wavURL.path)[.size]) as? Int ?? 0
            guard wavSize > 44_000 else { throw BookStreamError.audioRenderFailed("WAV 过小: \(wavSize)") }
            print("TTS OK: \(String(format: "%.2f", totalDuration))s 音频, \(result.segments.count) 段, WAV \(wavSize) 字节")

            // 1.5) 本地 AI 音色（Piper）：若已安装模型则端到端验证
            let models = PiperTTS.listModels()
            if let piperVoice = models.first {
                do {
                    let aiWAV = dir.appendingPathComponent("ai-voice.wav")
                    let aiResult = try await engine.renderBook(
                        sentences: sentences,
                        outputURL: aiWAV,
                        voiceIdentifier: nil,
                        piperVoice: piperVoice,
                        rate: 0.5,
                        progress: audioProgress,
                        cancellation: cancelled
                    )
                    let aiSize = (try? fm.attributesOfItem(atPath: aiWAV.path)[.size]) as? Int ?? 0
                    guard aiSize > 44_000, aiResult.segments.count == sentences.count else {
                        throw BookStreamError.audioRenderFailed("AI 音色输出异常: \(aiSize) 字节")
                    }
                    print("AI VOICE OK: \(piperVoice.displayName) [\(piperVoice.language)]，\(String(format: "%.2f", aiResult.segments.last?.end ?? 0))s 音频, \(aiSize) 字节")
                } catch {
                    let ns = error as NSError
                    print("AI DEBUG ERROR: \(String(describing: error)) | domain=\(ns.domain) code=\(ns.code)")
                    throw error
                }
            } else {
                print("AI VOICE SKIP: 未安装本地 Piper 音色模型")
            }

            // 1.6) 字幕旁白溢出策略验证（紧窗口强制触发溢出）
            let tightEntries = [
                SubtitleEntry(id: 0, start: 0.0, end: 0.5, text: "This line is deliberately long enough to overflow its window."),
                SubtitleEntry(id: 1, start: 0.5, end: 1.0, text: "The second narration line will also exceed the half second slot."),
                SubtitleEntry(id: 2, start: 1.0, end: 1.5, text: "And the third one keeps the test going until it finishes."),
            ]
            let extWAV = dir.appendingPathComponent("overflow-extend.wav")
            let extResult = try await engine.renderSubtitleAudio(
                entries: tightEntries, outputURL: extWAV,
                voiceIdentifier: nil, piperVoice: nil, rate: 0.5,
                overflowPolicy: .extend, progress: audioProgress, cancellation: cancelled
            )
            let extLen = (try? fm.attributesOfItem(atPath: extWAV.path)[.size]) as? Int ?? 0
            let extDur = extResult.segments.last?.end ?? 0
            guard extLen > 44_000, extDur > 1.5, !extResult.warnings.isEmpty else {
                throw BookStreamError.audioRenderFailed("溢出顺延策略验证失败: dur=\(extDur) 告警=\(extResult.warnings.count)")
            }
            print("OVERFLOW-EXTEND OK: 总时长 \(String(format: "%.2f", extDur))s（原窗口 1.5s，已顺延）· 告警 \(extResult.warnings.count) 条")

            let truncWAV = dir.appendingPathComponent("overflow-truncate.wav")
            let truncResult = try await engine.renderSubtitleAudio(
                entries: tightEntries, outputURL: truncWAV,
                voiceIdentifier: nil, piperVoice: nil, rate: 0.5,
                overflowPolicy: .truncate, progress: audioProgress, cancellation: cancelled
            )
            let truncDur = truncResult.segments.last?.end ?? 0
            guard abs(truncDur - 1.5) < 0.05, truncResult.warnings.contains(where: { $0.contains("截断") }) else {
                throw BookStreamError.audioRenderFailed("溢出截断策略验证失败: dur=\(truncDur)")
            }
            print("OVERFLOW-TRUNCATE OK: 总时长 \(String(format: "%.2f", truncDur))s（严格按原窗口）· 告警 \(truncResult.warnings.count) 条")

            // 2) SRT + ASS 写出（模式一输出）
            let srtURL = dir.appendingPathComponent("selftest.srt")
            try SrtWriter.write(segments: result.segments, to: srtURL)
            let srtText = try String(contentsOf: srtURL, encoding: .utf8)
            guard srtText.contains("-->") else { throw BookStreamError.audioRenderFailed("SRT 内容异常") }
            print("SRT OK: \(srtURL.lastPathComponent)")
            let assURL = dir.appendingPathComponent("selftest.ass")
            try AssWriter.write(segments: result.segments, highlight: .vividOrange, to: assURL)
            let assEntries = try AssParser.parse(url: assURL)
            guard assEntries.count == sentences.count else {
                throw BookStreamError.audioRenderFailed("ASS 往返解析失败: \(assEntries.count)")
            }
            print("ASS OK: \(assURL.lastPathComponent)（往返解析 \(assEntries.count) 条）")

            // 3) 视频渲染 → 1080p MP4
            let renderer = VideoRenderer()
            let mp4URL = dir.appendingPathComponent("selftest.mp4")
            let videoProgress: @Sendable @MainActor (Double) -> Void = { _ in }
            try await renderer.render(
                audioURL: wavURL,
                segments: result.segments,
                outputURL: mp4URL,
                style: CaptionStyle(),
                progress: videoProgress,
                cancellation: cancelled
            )
            let mp4Size = (try? fm.attributesOfItem(atPath: mp4URL.path)[.size]) as? Int ?? 0
            guard mp4Size > 100_000 else { throw BookStreamError.videoRenderFailed("MP4 过小: \(mp4Size)") }
            print("VIDEO OK: \(mp4URL.lastPathComponent), \(mp4Size) 字节, \(Int(totalDuration * 30)) 帧")

            // 4) 解耦验证：由「SRT 解析 + 已有 WAV」直接渲染视频（完全跳过 TTS）
            let decoupledURL = dir.appendingPathComponent("decoupled.mp4")
            let segmentsFromSRT = assEntries.map {
                TimedSegment(
                    id: $0.id,
                    text: $0.text,
                    startFrame: Int64(($0.start * AudioFormat.sampleRate).rounded()),
                    endFrame: Int64(($0.end * AudioFormat.sampleRate).rounded())
                )
            }
            try await renderer.render(
                audioURL: wavURL,
                segments: segmentsFromSRT,
                outputURL: decoupledURL,
                style: CaptionStyle(highlight: .cyan),
                progress: videoProgress,
                cancellation: cancelled
            )
            let decoupledSize = (try? fm.attributesOfItem(atPath: decoupledURL.path)[.size]) as? Int ?? 0
            guard decoupledSize > 100_000 else { throw BookStreamError.videoRenderFailed("解耦视频过小: \(decoupledSize)") }
            print("DECOUPLED OK: 由 SRT 时间轴 + 已有 WAV 渲染，无 TTS，\(decoupledSize) 字节")

            print("SELFTEST PASSED")
        } catch {
            print("SELFTEST FAILED: \(error)")
            exit(1)
        }
    }
}
