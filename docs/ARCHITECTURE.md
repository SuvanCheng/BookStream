# BookStream 技术架构（Turn 1 方案评审）

> 对应 `BookStream.yaml` 的 Turn 1 交付物：全链路数据流、时钟对齐、并发模型、模块清单。

## 1. 全链路数据流

```
┌────────────┐   ┌──────────────┐   ┌──────────────────┐   ┌────────────────┐
│ Text Parser│ → │ Utterance    │ → │ Offline Audio    │ → │ PCM Converter  │
│ TXT/EPUB   │   │ Queue        │   │ Synthesis        │   │ (44.1k mono    │
│ SRT/ASS    │   │ (分句队列)    │   │ AVSpeechSynth    │   │  float32)      │
└────────────┘   └──────────────┘   │ .write(buffer)   │   └───────┬────────┘
                                    └──────────────────┘           │
                                         帧计数累加                ▼
                                    ┌──────────────────┐   ┌───────────────┐
                                    │ Timestamp Index  │ → │ AVAudioFile   │
                                    │ Table (SRT)      │   │ WAV 16-bit    │
                                    └────────┬─────────┘   └───────┬───────┘
                                             │                     │
                                             ▼                     ▼
┌──────────────┐   ┌──────────────────┐   ┌────────┐   ┌───────────────────┐
│ CoreText     │ → │ CVPixelBufferPool│ → │ 30fps  │ → │ AVAssetWriter     │
│ Frame Render │   │ (32BGRA 复用)     │   │ PTS    │   │ H.264+AAC 双轨混流  │
└──────────────┘   └──────────────────┘   └────────┘   └───────────────────┘
                                                       MP4 (分辨率/码率可选)
```

## 2. 核心技术痛点解法

### 2.1 `AVSpeechSynthesizer.write` 离线抓轨

- **完成判定（实测验证，macOS 26 SDK）**：`write(_:toBufferCallback:)` 的缓冲回调在
  句尾会连续投递若干个 `frameLength == 0` 的空缓冲作为流终止信号；实现上收到 0 帧缓冲且
  0.3 秒内无任何新回调即判定本句渲染完毕。**不依赖任何 Delegate 回调**。
- **回调投递线程（关键实测）**：缓冲回调投递到**发起 `write()` 的线程**的 run loop，
  且该线程 run loop 的**首次交互必须发生在 `write()` 之后**（任何预先的 run/timer
  活动都会令回调完全不触发）；GCD 工作线程无法服务该回调（应用内实测零回调）。
  因此音频引擎运行在**专属 NSThread** 上，init 时只轮询任务 FIFO（不触碰 run loop），
  首个 run loop 交互发生在 renderOne 的 `write()` 之后。
- **禁止 `preUtteranceDelay` / `postUtteranceDelay`（关键实测）**：该设置会令
  `write(toBufferCallback:)` 的缓冲回调完全不触发（合成静默走了不同内部路径），
  导致抓轨挂死（实测逐一隔离确认；rate/pitch 无此问题）。
- **重采样**：回调产出的缓冲为系统动态采样率（实测默认 22050 Hz），通过
  `AVAudioConverter`（拉模式，`convert(to:error:withInputFrom:)`）统一转换为
  44.1 kHz / 单声道 / float32，再写入 16-bit WAV `AVAudioFile`。
- **帧计数时间戳**：`duration = frameCount / 44100.0`（每句实际产出帧数），
  逐句累加得到全局绝对时间戳；SRT 毫秒数由 `round(t * 1000)` 得出。
- **防死锁**：抓轨过程在音频线程上驱动自身 run loop 轮询完成旗标，附带 10 分钟看门狗；
  缓冲收集使用 `NSLock` 保护的 Sendable 容器。

### 2.2 双轨背压与像素缓冲复用

- 视频 PTS = `frameIndex / 30`；音频 PTS = `sampleCount / 44100`（WAV 采样缓冲自带）。
- 单串行队列交替驱动：音频仅在其 PTS ≤ 当前视频时间时追加（防止音频超前堆积）；
  任一输入端 `isReadyForMoreMediaData == false` 时 `sleep(5ms)` 让步重试，绝不阻塞等待。
- **实测约束**：`AVAssetWriter` 必须在与驱动循环相同的串行队列线程上创建与写入
  （放入 Swift `Task`/协作线程池会导致视频输入端在约 2 秒缓冲后永久不再就绪、
  编码器不排空——已实测复现并规避）。
- 每帧在 `autoreleasepool` 内从 `CVPixelBufferPool` 分配 32BGRA 缓冲、
  绘制后立即解锁返回池中复用，杜绝帧缓存堆积引发 OOM。

### 2.3 滚动字幕渲染（从下往上，锚定中心）

- **当前句锚定画面中心**（高亮色 + 72pt 粗体，无底色），整句朗读期间不漂移；
- 已结束的历史句从中心向上滚动，5 秒内淡化淡出；未开始的未来句从底部上移接近，
  3 秒内渐显进入——**历史与未来同屏可见**；
- **无重叠约束**：逐行按实际行高 + 间距（22px）做约束传递，任意两行绝不重叠
  （密集字幕场景亦不会叠字）；
- 高亮色由 UI 调色盘（9 色）传入 `CaptionStyle`（纯 RGB Sendable 结构）；
- 排版按 `(segmentID, 是否高亮)` 双键缓存（`CTFramesetter` + 尺寸），逐帧仅绘制
  时间窗内可见行；
- **方向性（关键修正）**：`CTFrameDraw` 在非翻转的 `CGBitmapContext`（y 向上）中
  直接输出正向文字；曾误加 `translate + scale(-1)` 翻转，实测导致文字整体旋转 180°
  （上下颠倒 + 左右镜像，用户在多台设备上复现）。已移除翻转并将定位坐标改为 y 向上，
  通过「渲染器原始内存转储（`BOOKSTREAM_FRAMEDUMP`）+ 视频轨道 AVAssetReader 直接
  读像素 + 与无翻转参考做相关比对」三重验证正向。

### 2.4 输出解耦

- **音频 + SRT/ASS** 与**视频**两条导出链路完全独立，互不依赖：
  - 视频模式自包含：内部 TTS 抓轨仅生成临时音频轨（不产出/不读取任何 .srt 文件）；
  - 支持「字幕 + 已有音频」复用：加载字幕文件后可附带 wav/m4a/mp3，直接按字幕
    时间轴渲染视频，**完全跳过 TTS**（模式一的输出可直接被模式二消费，反之亦然）；
- 模式一同时输出 **SRT + ASS**（ASS 携带所选高亮色样式，供外部工具使用）。

### 2.5 Swift 6 并发安全模型

- `AudioEngine` / `VideoRenderer` 为 `@unchecked Sendable`，全部 AVFoundation 对象
  约束在各自专属串行队列内，非 Sendable 值**不跨越隔离域**；
- 跨隔离域传递的仅限 `Sendable` 值（`[String]`、`[TimedSegment]`、`URL`）；
- 进度回调类型为 `@Sendable @MainActor (…)->Void`，引擎在回调处主动
  `DispatchQueue.main.async + MainActor.assumeIsolated` 切回主线程；
- 取消：`OSAllocatedUnfairLock<Bool>` 作为线程安全取消旗标，队列循环逐句/逐帧检查；
- UI 状态模型 `@MainActor AppModel: ObservableObject`，所有 `@Published` 变更在主线程。

## 3. 状态机

```
Idle ──载入文件──▶ Parsed ──开始生成──▶ Processing
                                          │  ├─ 阶段一: TTS 抓轨 (逐句)
                                          │  └─ 阶段二(视频): 双轨渲染 (逐帧)
        ┌──────────────────────────────────┘
        ▼
   Finished (预览可用)      Cancelled / Failed (清理临时文件)
```

## 4. 模块清单与职能

| 文件 | 职能 |
|---|---|
| `Package.swift` | SPM 可执行 Target，macOS 13+，Swift 6 语言模式 |
| `Models.swift` | 数据模型；TXT/EPUB/SRT/ASS 解析；标点分句；SRT 写出 |
| `AudioEngine.swift` | TTS 离线抓轨、重采样、WAV 拼接、采样帧时间戳推导（Actor/串行队列） |
| `VideoSynthesizer.swift` | 滚动字幕排版（可调高亮色）、AVAssetReader/Writer 双轨混流、像素缓冲池 |
| `ContentView.swift` | SwiftUI 界面：拖拽区、声音质量排序+试听、语速、模式、调色盘、进度、日志、AVPlayer 预览 |
| `BookStreamApp.swift` | `@main` 入口（含 `--selftest` / `--parse` 无头模式） |
| `SelfTest.swift` | 无头端到端自检（`--keep` 保留输出） |
| `Scripts/make_icon.swift` | 应用图标生成器（CoreGraphics 绘制 → iconset → icns） |
| `Resources/AppIcon.icns` | 应用图标（build.sh 复制进 Bundle，Info.plist 引用） |
| `build.sh` | SPM 编译 → .app 骨架 → Info.plist（含图标）→ Ad-hoc 签名 → 启动 |
