# BookStream

macOS 原生离线有声书 / 字幕视频生成器（纯终端一键构建，Swift 6 严格并发）。

## 功能

- 输入：`.txt` / `.epub`（电子书）、`.srt` / `.ass` / `.ssa`（字幕）
- **模式一 · 离线音频 + SRT + ASS**：`AVSpeechSynthesizer.write` 离线抓轨，按实际产出
  PCM 帧数（44.1 kHz）精确推导毫秒级时间戳，输出无损 WAV + 合规 UTF-8 SRT + 带高亮色
  样式的 ASS（供外部播放器/工具使用）
- **模式二 · 动态字幕视频（默认）**：**当前句锚定画面中心**（醒目高亮 + 大字号，无底色），
  历史字幕以恒定速度向上滚动淡化淡出、未来字幕以同速接近渐显——恒定速度保证观感
  稳定丝滑；所有行按「行高均值 + 间隙」间距约束，任意两行绝不重叠；高亮色带 9 色调色盘
  + **分辨率 480p/720p/1080p/4K 可选**；**水印**（文本/图片，9 宫格位置、字号/大小、
  透明度、颜色可调，随分辨率等比缩放）；AVAssetWriter H.264 硬件编码 @ 30fps MP4，
  内嵌 AVPlayer 回放预览
- **两条导出链路完全解耦**：视频模式自包含（内部自动生成音频轨，不涉及 SRT）；
  加载字幕文件后还可**附带已有音频（wav/m4a/mp3）直接渲染视频，完全跳过 TTS**——
  模式一的产物可直接被模式二复用，互不依赖
- **声音**：质量优先排序（Premium/增强/默认），排除系统特效音色，按内容语言
  （中/日/韩/俄/阿/希伯来/泰/印地/希腊/德/西/法/北欧…）自动选择最优自然音色
  （如 Samantha / Tingting），支持「试听」；**停顿感**滑块调节句间/段间停顿倍率
  （段末自动 1.0s、句间 0.4s 停顿），AI 音色支持合成试听
- **本地 AI 音色（Piper 神经网络 TTS）**：完全本地离线的 AI 语音——应用内一键
  「安装引擎」（`pip3 install piper-tts`，一次性联网）+「下载音色」（中/英文各一，
  一次性），此后合成全程离线；引擎按 应用支持目录原生二进制 / PATH / `python3 -m piper`
  依次探测，音色模型放于 `~/Library/Application Support/BookStream/piper/models/`
- 下载模型地址：https://huggingface.co/rhasspy/piper-voices/tree/main
- 100% 本地离线：合成管线无任何云端 API（仅引擎/模型一次性安装需联网）
- 自带应用图标（`Resources/AppIcon.icns`，`Scripts/make_icon.swift` 可重新生成）

## 构建与运行

```bash
./build.sh              # 编译 → 打包 .app → 签名 → 启动
./build.sh --no-launch  # 仅打包不启动
swift run BookStream --selftest        # 无头端到端自检（TTS→WAV→SRT→MP4）
swift run BookStream --parse <file>    # 解析校验（txt/epub/srt/ass/ssa）
```

要求：macOS 13+，Xcode Command Line Tools（Swift 6）。

## 工程结构

```
Package.swift                     SPM 清单（macOS 13+，Swift 6 语言模式）
Sources/BookStream/
  Models.swift                    数据模型 + TXT/EPUB/SRT/ASS 解析 + 分句 + SRT 写出
  AudioEngine.swift               TTS 离线抓轨 + AVAudioConverter 重采样 + WAV 拼接
  VideoSynthesizer.swift          滚动字幕排版（可调高亮色）+ AVAssetReader/Writer 双轨混流
  ContentView.swift               SwiftUI 界面（拖拽/声音质量排序/语速/模式/调色盘/日志/预览）
  BookStreamApp.swift             @main 入口（含 --selftest / --parse 无头模式）
  SelfTest.swift                  无头端到端自检
Scripts/make_icon.swift           应用图标生成器（CoreGraphics 绘制 → icns）
Resources/AppIcon.icns            应用图标
build.sh                          一键构建打包签名启动
docs/ARCHITECTURE.md              架构与时钟对齐方案（Turn 1 文档）
books/odyssey.txt                 示例书籍
```

## 关于更自然的人声

本机系统默认只带「默认」质量音色（英文最优为 Samantha，中文为 Tingting）。
想要更接近真人声线，请在 **系统设置 → 语音 → 系统声音** 下载 Apple 的
Enhanced / Premium（Siri）音色；下载后应用会自动把它们排在列表最前并标为
「增强 / Premium」，默认选中最优音色。

## 快速体验

1. `./build.sh --no-launch`
2. 打开 `dist/BookStream.app`，把 `books/odyssey.txt` 拖入左侧面板
3. 选择声音与语速，选择导出模式，点击「开始生成」
