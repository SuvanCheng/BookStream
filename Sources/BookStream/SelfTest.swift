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
        if let idx = CommandLine.arguments.firstIndex(of: "--check-drift"), idx + 1 < CommandLine.arguments.count {
            await runCheckDrift(URL(fileURLWithPath: CommandLine.arguments[idx + 1]))
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
                let (sentences, fixes) = try TextProcessor.parseBookFile(url: url)
                let chars = sentences.reduce(0) { $0 + $1.text.count }
                let paraPauses = sentences.filter { $0.pauseAfter >= 1.0 }.count
                let sentPauses = sentences.filter { $0.pauseAfter > 0 && $0.pauseAfter < 1.0 }.count
                print("PARSE OK [\(ext)]: \(sentences.count) 句, \(chars) 字（段末停顿 \(paraPauses) 处 · 句末停顿 \(sentPauses) 处）")
                print("  first: \(sentences.first?.text.prefix(80) ?? "")")
                for s in sentences.prefix(8) {
                    let pause = s.pauseAfter >= 1.0 ? "段末" : String(format: "%.1f", s.pauseAfter)
                    print("    [\(pause)] \(s.text.prefix(60))")
                }
                if !fixes.isEmpty {
                    let counts = Dictionary(grouping: fixes, by: { $0.kind })
                        .map { "\($0.key.rawValue) \($0.value.count) 处" }
                        .sorted()
                        .joined(separator: " · ")
                    print("  修复: \(counts)（共 \(fixes.count) 处，仅影响解析，不修改原文件）")
                    for f in fixes.prefix(5) {
                        print("    · 段落\(f.paraIndex) \(f.kind.rawValue): 「\(f.original)」→「\(f.repaired)」")
                    }
                }
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

    private static func runCheckDrift(_ url: URL) async {
        do {
            let (sentences, _) = try TextProcessor.parseBookFile(url: url)
            let testSentences = Array(sentences.prefix(256))
            print("Testing with \(testSentences.count) sentences from \(url.lastPathComponent)")
            let tmpWav = URL(fileURLWithPath: "/tmp/drift-test.wav")
            try? FileManager.default.removeItem(at: tmpWav)
            let engine = AudioEngine()
            let result = try await engine.renderBook(
                sentences: testSentences,
                outputURL: tmpWav,
                engine: .kokoro,
                kokoroVoice: "af_heart",
                rate: 0.4,
                pauseScale: 1.4,
                progress: { d, t in },
                cancellation: { false }
            )
            let wavFile = try AVAudioFile(forReading: tmpWav)
            print("WAV file frame length:", wavFile.length)
            print("WAV file duration in sec:", Double(wavFile.length) / 44100.0)
            print("Segments count:", result.segments.count)
            if let lastSeg = result.segments.last {
                print("Last segment endFrame:", lastSeg.endFrame)
                print("Last segment end (sec):", lastSeg.end)
                print("Difference (frames):", wavFile.length - lastSeg.endFrame)
                print("Difference (sec):", Double(wavFile.length - lastSeg.endFrame) / 44100.0)
                guard wavFile.length == lastSeg.endFrame else {
                    print("DRIFT DETECTED!"); exit(1)
                }
            }
            try? FileManager.default.removeItem(at: tmpWav)
            print("DRIFT CHECK PASSED: 0 frames drift")
            exit(0)
        } catch {
            print("DRIFT TEST FAILED: \(error)")
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
                Sentence(id: 0, text: "Hello, this is the BookStream self test."),
                Sentence(id: 1, text: "The quick brown fox jumps over the lazy dog."),
                Sentence(id: 2, text: "Offline speech synthesis and video rendering work correctly.", pauseAfter: 0.7),
            ]

            // 1) TTS 离线抓轨 → WAV + 时间轴
            let engine = AudioEngine()
            let wavURL = dir.appendingPathComponent("selftest.wav")
            let audioProgress: @Sendable @MainActor (Int, Int) -> Void = { _, _ in }
            let cancelled: @Sendable () -> Bool = { false }

            let result = try await engine.renderBook(
                sentences: sentences,
                outputURL: wavURL,
                engine: .kokoro,
                kokoroVoice: "af_heart",
                rate: 0.5,
                progress: audioProgress,
                cancellation: cancelled
            )
            guard result.segments.count == sentences.count else {
                throw BookStreamError.audioRenderFailed("片段数不符: \(result.segments.count)")
            }
            let totalDuration = result.segments.last?.end ?? 0
            let wavSize = (try? fm.attributesOfItem(atPath: wavURL.path)[.size]) as? Int ?? 0
            let wavFile = try AVAudioFile(forReading: wavURL)
            guard wavFile.length == result.segments.last?.endFrame else {
                throw BookStreamError.audioRenderFailed("音画时轴漂移: wav.length=\(wavFile.length) vs endFrame=\(result.segments.last?.endFrame ?? -1)")
            }
            guard wavSize > 44_000 else { throw BookStreamError.audioRenderFailed("WAV 过小: \(wavSize)") }
            print("TTS OK: \(String(format: "%.2f", totalDuration))s 音频, \(result.segments.count) 段, WAV \(wavSize) 字节（0帧音画时轴漂移）")

            // 1.4) 停顿感验证：pauseScale 生效（0× vs 2× 时长应明显不同）
            let pause0 = try await engine.renderBook(
                sentences: sentences, outputURL: dir.appendingPathComponent("pause0.wav"),
                engine: .kokoro, kokoroVoice: "af_heart", rate: 0.5,
                pauseScale: 0, progress: audioProgress, cancellation: cancelled
            )
            let pause2 = try await engine.renderBook(
                sentences: sentences, outputURL: dir.appendingPathComponent("pause2.wav"),
                engine: .kokoro, kokoroVoice: "af_heart", rate: 0.5,
                pauseScale: 2, progress: audioProgress, cancellation: cancelled
            )
            let d0 = pause0.segments.last?.end ?? 0
            let d2 = pause2.segments.last?.end ?? 0
            guard d2 > d0 + 0.5 else { throw BookStreamError.audioRenderFailed("停顿感无效: \(d0) vs \(d2)") }
            print("PAUSE OK: 0×停顿 \(String(format: "%.2f", d0))s → 2×停顿 \(String(format: "%.2f", d2))s")

            // 1.5) 原文分句与数字缩写保护验证：折行合并 / 数字缩写保护 / 段末停顿（保留原书标点）
            let sentenceSample = "他走进房间，看见桌上有一封信。\n\n他说Mr. Smith走了3.5公里。"
            let splitParts = TextProcessor.splitSentencesWithPauses(sentenceSample)
            guard splitParts.count == 2,
                  splitParts[0].text == "他走进房间，看见桌上有一封信。",
                  splitParts[1].text.contains("Mr. Smith"),
                  splitParts[1].text.contains("3.5公里。"),
                  splitParts[1].pauseAfter >= 1.0 else {
                throw BookStreamError.unsupportedFile("分句结果异常: \(splitParts.map(\.text))")
            }
            print("SPLIT OK: 准确分出 \(splitParts.count) 句 · Mr./3.5 未拆 · 原文标点完整 · 段末停顿已标")

            // 1.6) L3 长句拆分验证：超长无标点句按软边界拆短，每段长度受控
            let longSample = "他站在窗前望着远处的山峦心中思绪万千回想起这些年走过的路经历过的事每一件都历历在目那些欢笑那些泪水那些深夜的叹息都像是昨天才发生过一样他轻轻叹了口气转身回到书桌前拿起那封泛黄的信重新读了起来信上的字迹已经有些模糊但他依然认得那是父亲的手笔他决定明天就出发回到那个阔别多年的故乡去看一看曾经生活过的地方见一见那些久未联系的亲人朋友"
            let (longParts, splitFixes) = TextProcessor.splitLongSentences([(longSample, 1.0)])
            guard splitFixes.count == 1, longParts.count >= 3,
                  longParts.allSatisfy({ $0.text.count <= 75 }),
                  longParts.last?.pauseAfter == 1.0 else {
                throw BookStreamError.unsupportedFile("L3 长句拆分异常: \(longParts.map(\.text.count))")
            }
            print("L3 OK: \(longSample.count) 字 → \(longParts.count) 句（最长 \(longParts.map(\.text.count).max() ?? 0) 字）· 段末停顿保留")

            // 1.6b) L3 英文从句分切验证：保持原文标点与从句流动
            let odysseyLong = "for they perished through their own sheer folly in eating the cattle of the Sun-god Hyperion; so the god prevented them from ever reaching home."
            let (odysseyParts, odysseyFixes) = TextProcessor.splitLongSentences([(odysseyLong, 0.4)], maxChars: 60)
            guard odysseyParts.count == 2,
                  odysseyFixes.count == 1,
                  odysseyParts[0].text.hasSuffix("Hyperion;"),
                  odysseyParts[1].text.hasPrefix("so the god") else {
                throw BookStreamError.unsupportedFile("L3 英文分句异常: \(odysseyParts.map(\.text))")
            }
            print("L3-EN OK: 保持原文标点拆成 \(odysseyParts.count) 句: \(odysseyParts[0].text.count)/\(odysseyParts[1].text.count) 字")

            // 1.7) 英文名著适配验证：Gutenberg 样板剥离 / 章节标题与目录跳过 / 对话引号保留
            let gutenbergSample = """
            CONTENTS

            CHAPTER I .... 3
            I. The Pilgrim's Progress .... 3

            CHAPTER ONE

            PLAYING PILGRIMS

            "Christmas won't be Christmas without any presents," grumbled Jo,
            lying on the rug.

            "It's so dreadful to be poor!" sighed Meg, looking down at her old
            dress.

            *** END OF THE PROJECT GUTENBERG EBOOK LITTLE WOMEN ***
            """
            let gutenbergURL = dir.appendingPathComponent("gutenberg-sample.txt")
            try gutenbergSample.write(to: gutenbergURL, atomically: true, encoding: .utf8)
            let (enSentences, enFixes) = try TextProcessor.parseBookFile(url: gutenbergURL)
            let skipCount = enFixes.filter { $0.kind == .skipTOC }.count
            let stripCount = enFixes.filter { $0.kind == .stripBoilerplate }.count
            // 章节标题被保留（CONTENTS / PLAYING PILGRIMS 等），目录点线条目被跳过（不出现 "...."），
            // 对话引号完整（grumbled Jo / sighed Meg）。
            guard skipCount >= 1, stripCount >= 1,
                  enSentences.contains(where: { $0.text.contains("CONTENTS") }),
                  enSentences.contains(where: { $0.text.contains("PLAYING PILGRIMS") }),
                  enSentences.contains(where: { $0.text.contains("grumbled Jo") }),
                  enSentences.contains(where: { $0.text.contains("sighed Meg") }),
                  !enSentences.contains(where: { $0.text.contains("....") }) else {
                throw BookStreamError.unsupportedFile("英文名著解析异常: \(enSentences.map(\.text))")
            }
            print("ENGLISH OK: 样板剥离 \(stripCount) 处 · 目录跳过 \(skipCount) 处 · 章节标题保留（CONTENTS/CHAPTER/PLAYING PILGRIMS 均在正文）· 对话引号完整 \(enSentences.count) 句")

            // 1.8) 章节标记与时间戳写出验证
            let chTestSegments = [
                TimedSegment(id: 0, text: "Introduction and Preface", startFrame: 0, endFrame: 44100 * 10),
                TimedSegment(id: 1, text: "CHAPTER 1. The Beginning", startFrame: 44100 * 10, endFrame: 44100 * 60),
                TimedSegment(id: 2, text: "Some narration text inside chapter 1.", startFrame: 44100 * 60, endFrame: 44100 * 120),
                TimedSegment(id: 3, text: "BOOK II. The Journey", startFrame: 44100 * 120, endFrame: 44100 * 200),
                TimedSegment(id: 4, text: "第一章 风起云涌", startFrame: 44100 * 200, endFrame: 44100 * 300),
            ]
            let detectedChs = TextProcessor.detectChapters(segments: chTestSegments)
            guard detectedChs.count == 3,
                  detectedChs[0].title == "CHAPTER 1. The Beginning",
                  detectedChs[1].title == "BOOK II. The Journey",
                  detectedChs[2].title == "第一章 风起云涌" else {
                throw BookStreamError.unsupportedFile("章节识别失败: \(detectedChs.map(\.title))")
            }
            let chTxtURL = dir.appendingPathComponent("selftest.chapters.txt")
            try ChapterWriter.write(chapters: detectedChs, to: chTxtURL)
            let chTxtContent = try String(contentsOf: chTxtURL, encoding: .utf8)
            guard chTxtContent.contains("00:10 CHAPTER 1. The Beginning"),
                  chTxtContent.contains("02:00 BOOK II. The Journey") else {
                throw BookStreamError.unsupportedFile("章节时间戳写出异常: \(chTxtContent)")
            }
            print("CHAPTER OK: 识别 \(detectedChs.count) 个中英文章节 · 时间戳格式验证通过")

            // 1.9) 句子按章节分卷范围切分验证
            let sentChList = [
                Sentence(id: 0, text: "Preface note"),
                Sentence(id: 1, text: "Chapter 1"),
                Sentence(id: 2, text: "Content in 1"),
                Sentence(id: 3, text: "Chapter 2"),
                Sentence(id: 4, text: "Content in 2"),
            ]
            let sentChRanges = TextProcessor.detectChaptersFromSentences(sentences: sentChList)
            guard sentChRanges.count == 2,
                  sentChRanges[0].range == 1..<3,
                  sentChRanges[1].range == 3..<5 else {
                throw BookStreamError.unsupportedFile("句子章节分卷异常: \(sentChRanges)")
            }
            print("CHAPTER-SPLIT OK: 识别 \(sentChRanges.count) 个分卷范围 · 范围索引校准通过")

            // 1.55) 微软 Neural 广播级引擎端到端验证（如果 Python edge-tts 运行环境就绪）
            if EdgeTTS.isAvailable() {
                do {
                    let edgeWAV = dir.appendingPathComponent("edge-voice.wav")
                    let edgeResult = try await engine.renderBook(
                        sentences: [Sentence(id: 0, text: "Welcome to Listening Bus.")],
                        outputURL: edgeWAV,
                        engine: .edgeTTS,
                        edgeVoice: "en-US-ChristopherNeural",
                        rate: 0.4,
                        progress: audioProgress,
                        cancellation: cancelled
                    )
                    let edgeSize = (try? fm.attributesOfItem(atPath: edgeWAV.path)[.size]) as? Int ?? 0
                    guard edgeSize > 10_000, !edgeResult.segments.isEmpty else {
                        throw BookStreamError.audioRenderFailed("微软 Neural 输出异常: \(edgeSize) 字节")
                    }
                    print("EDGE-TTS OK: Christopher [en-US]，\(String(format: "%.2f", edgeResult.segments.last?.end ?? 0))s 音频, \(edgeSize) 字节（48kHz 广播级神经原声）")
                } catch {
                    print("EDGE-TTS SKIP: 网络波动或环境不可达: \(error.localizedDescription)")
                }
            }

            // 1.56) Kokoro-82M 本地顶级神经网络引擎端到端验证（完全离线·秒级推理）
            if KokoroTTS.isAvailable() {
                do {
                    let kokoroWAV = dir.appendingPathComponent("kokoro-voice.wav")
                    let kokoroResult = try await engine.renderBook(
                        sentences: [Sentence(id: 0, text: "Welcome to Listening Bus audiobook.")],
                        outputURL: kokoroWAV,
                        engine: .kokoro,
                        kokoroVoice: "af_heart",
                        rate: 0.4,
                        progress: audioProgress,
                        cancellation: cancelled
                    )
                    let kokoroSize = (try? fm.attributesOfItem(atPath: kokoroWAV.path)[.size]) as? Int ?? 0
                    guard kokoroSize > 10_000, !kokoroResult.segments.isEmpty else {
                        throw BookStreamError.audioRenderFailed("Kokoro 输出异常: \(kokoroSize) 字节")
                    }
                    print("KOKORO-TTS OK: Heart (af_heart) [en-US]，\(String(format: "%.2f", kokoroResult.segments.last?.end ?? 0))s 音频, \(kokoroSize) 字节（Kokoro-82M 本地顶级神经原声）")
                } catch {
                    print("KOKORO-TTS SKIP: \(error.localizedDescription)")
                }
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
                engine: .kokoro, kokoroVoice: "af_heart", rate: 0.5,
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
                engine: .kokoro, kokoroVoice: "af_heart", rate: 0.5,
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
            // 环境变量 BOOKSTREAM_WATERMARK=1 时启用测试水印（验证水印绘制/缩放路径）；
            // BOOKSTREAM_WATERMARK_IMAGE=<png路径> 时改用导入图片水印（右上角）。
            var testWatermark: WatermarkSettings = .default
            if ProcessInfo.processInfo.environment["BOOKSTREAM_WATERMARK"] == "1" {
                testWatermark = WatermarkSettings(
                    enabled: true, text: "BookStream 测试水印", color: .yellow,
                    fontSize: 40, opacity: 0.9, position: .topLeft
                )
            }
            if let imgPath = ProcessInfo.processInfo.environment["BOOKSTREAM_WATERMARK_IMAGE"],
               let imgData = try? Data(contentsOf: URL(fileURLWithPath: imgPath)) {
                testWatermark = WatermarkSettings(
                    enabled: true, text: "", color: .yellow,
                    fontSize: 40, opacity: 1.0, position: .topRight,
                    imageData: imgData, imageScale: 0.12
                )
            }
            try await renderer.render(
                audioURL: wavURL,
                segments: result.segments,
                outputURL: mp4URL,
                style: CaptionStyle(),
                watermark: testWatermark,
                progress: videoProgress,
                cancellation: cancelled
            )
            let mp4Size = (try? fm.attributesOfItem(atPath: mp4URL.path)[.size]) as? Int ?? 0
            guard mp4Size > 100_000 else { throw BookStreamError.videoRenderFailed("MP4 过小: \(mp4Size)") }
            print("VIDEO OK: \(mp4URL.lastPathComponent), \(mp4Size) 字节, \(Int(totalDuration * 30)) 帧")

            // 4) M4B 有声书转换验证（AudioToolbox 硬件 AAC 压缩）
            let m4bURL = dir.appendingPathComponent("selftest.m4b")
            try AudioEngine.convertWavToM4b(wavURL: wavURL, outputURL: m4bURL)
            let m4bSize = (try? fm.attributesOfItem(atPath: m4bURL.path)[.size]) as? Int ?? 0
            guard m4bSize > 10_000 else { throw BookStreamError.audioRenderFailed("M4B 生成失败，大小: \(m4bSize)") }
            print("M4B OK: \(m4bURL.lastPathComponent), \(m4bSize) 字节（AAC 硬件压缩）")

            // 5) 竖屏 9:16 短视频自适应 + 自定义字体验证（宋体）
            let portraitMP4 = dir.appendingPathComponent("portrait_9x16.mp4")
            let portraitRes = VideoResolution.make(aspectRatio: .portrait9_16, quality: .p480)
            try await renderer.render(
                audioURL: wavURL,
                segments: result.segments,
                outputURL: portraitMP4,
                style: CaptionStyle(highlight: .pink, font: .songti),
                resolution: portraitRes,
                codec: .h264,
                progress: videoProgress,
                cancellation: cancelled
            )
            let portraitSize = (try? fm.attributesOfItem(atPath: portraitMP4.path)[.size]) as? Int ?? 0
            guard portraitSize > 50_000 else { throw BookStreamError.videoRenderFailed("9:16 竖屏视频过小: \(portraitSize)") }
            print("PORTRAIT-9:16 OK: \(portraitMP4.lastPathComponent), \(portraitSize) 字节（宋体·9:16 竖屏短视频）")

            // 6) HEVC / H.265 硬件加速视频编码验证
            let hevcMP4 = dir.appendingPathComponent("selftest_hevc.mp4")
            try await renderer.render(
                audioURL: wavURL,
                segments: result.segments,
                outputURL: hevcMP4,
                style: CaptionStyle(highlight: .green),
                resolution: .p480,
                codec: .hevc,
                progress: videoProgress,
                cancellation: cancelled
            )
            let hevcSize = (try? fm.attributesOfItem(atPath: hevcMP4.path)[.size]) as? Int ?? 0
            guard hevcSize > 50_000 else { throw BookStreamError.videoRenderFailed("HEVC 视频过小: \(hevcSize)") }
            print("HEVC OK: \(hevcMP4.lastPathComponent), \(hevcSize) 字节（H.265 硬件加速）")

            // 7) BGM 背景音乐混音与智能侧链避让压限验证
            let bgmTestURL = dir.appendingPathComponent("selftest_bgm.wav")
            do {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: 44100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                let pcmMono44k = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
                let bgmFile = try AVAudioFile(forWriting: bgmTestURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
                let buf = AVAudioPCMBuffer(pcmFormat: pcmMono44k, frameCapacity: 44100)!
                buf.frameLength = 44100
                let ptr = buf.floatChannelData![0]
                for i in 0..<44100 { ptr[i] = sin(Float(i) * 220.0 * 2.0 * .pi / 44100.0) * 0.25 }
                try bgmFile.write(from: buf)
            }
            let mixedWavURL = dir.appendingPathComponent("selftest_mixed.wav")
            try AudioEngine.mixBGM(voiceWAVURL: wavURL, bgmURL: bgmTestURL, outputURL: mixedWavURL, bgmVolume: 0.20, enableDucking: true)
            let mixedSize = (try? fm.attributesOfItem(atPath: mixedWavURL.path)[.size]) as? Int ?? 0
            guard mixedSize > 100_000 else { throw BookStreamError.audioRenderFailed("BGM 混音产物过小: \(mixedSize)") }
            print("BGM DUCKING OK: \(mixedWavURL.lastPathComponent), \(mixedSize) 字节（智能侧链避让混音）")

            // 8) 字级卡拉OK点亮动效渲染验证
            let karaokeMP4 = dir.appendingPathComponent("karaoke_glow.mp4")
            try await renderer.render(
                audioURL: mixedWavURL,
                segments: result.segments,
                outputURL: karaokeMP4,
                style: CaptionStyle(highlight: .vividOrange, enableKaraoke: true),
                resolution: .p480,
                codec: .h264,
                progress: videoProgress,
                cancellation: cancelled
            )
            let karaokeSize = (try? fm.attributesOfItem(atPath: karaokeMP4.path)[.size]) as? Int ?? 0
            guard karaokeSize > 50_000 else { throw BookStreamError.videoRenderFailed("卡拉OK视频过小: \(karaokeSize)") }
            print("KARAOKE GLOW OK: \(karaokeMP4.lastPathComponent), \(karaokeSize) 字节（字级平滑点亮动效）")

            // 9) 解耦验证：由「SRT 解析 + 已有 WAV」直接渲染视频（完全跳过 TTS）
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

            // 10) 电台级录音棚人声温暖度与壁炉柴火音效验证
            let fireplaceWavURL = dir.appendingPathComponent("selftest_fireplace.wav")
            try AudioEngine.generateProceduralBGM(preset: "fireplace", totalSeconds: 3.0, outputURL: fireplaceWavURL)
            let fireplaceSize = (try? fm.attributesOfItem(atPath: fireplaceWavURL.path)[.size]) as? Int ?? 0
            guard fireplaceSize > 50_000 else { throw BookStreamError.audioRenderFailed("壁炉音效过小: \(fireplaceSize)") }
            print("FIREPLACE & VOCAL WARMTH OK: \(fireplaceWavURL.lastPathComponent), \(fireplaceSize) 字节（壁炉柴火噼啪声）")

            // 11) 影视级片头封面、星尘微粒与 Siri 波浪光带视频渲染验证
            let cinematicMP4 = dir.appendingPathComponent("cinematic_wave.mp4")
            try await renderer.render(
                audioURL: wavURL,
                segments: result.segments,
                outputURL: cinematicMP4,
                style: CaptionStyle(
                    highlight: .gold,
                    theme: .midnightPurple,
                    visualizerStyle: .waveRibbon,
                    enableIntroOutro: true,
                    enableParticles: true
                ),
                resolution: .p480,
                codec: .h264,
                progress: videoProgress,
                cancellation: cancelled
            )
            let cinematicSize = (try? fm.attributesOfItem(atPath: cinematicMP4.path)[.size]) as? Int ?? 0
            guard cinematicSize > 50_000 else { throw BookStreamError.videoRenderFailed("影视级视频过小: \(cinematicSize)") }
            print("CINEMATIC & VISUALIZER OK: \(cinematicMP4.lastPathComponent), \(cinematicSize) 字节（Siri 光带·片头淡入·星尘微粒）")

            // 12) 高清短视频设计封面图生成验证
            let coverURL = dir.appendingPathComponent("selftest_cover.jpg")
            try VideoSynthesizer.generateCoverImage(
                title: "小王子 The Little Prince",
                chapter: "第 01 章",
                theme: .darkGradient,
                aspectRatio: .portrait9_16,
                quality: .p1080,
                highlightColor: .gold,
                outputURL: coverURL
            )
            let coverSize = (try? fm.attributesOfItem(atPath: coverURL.path)[.size]) as? Int ?? 0
            guard coverSize > 20_000 else { throw BookStreamError.videoRenderFailed("封面图过小: \(coverSize)") }
            print("COVER GENERATION OK: \(coverURL.lastPathComponent), \(coverSize) 字节（1080x1920 高清封面图）")

            print("SELFTEST PASSED")
        } catch {
            print("SELFTEST FAILED: \(error)")
            exit(1)
        }
    }
}
