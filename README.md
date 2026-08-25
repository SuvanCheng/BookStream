# BookStream

macOS 原生离线有声书 / 字幕视频生成器（纯终端一键构建，Swift 6 严格并发）。

## 快捷键指南

BookStream 全面支持 macOS 原生快捷键与全局菜单，助你高效批量生产：

| 快捷键 | 功能名称 | 详细说明 |
| :--- | :--- | :--- |
| **`⌘ + I`** (`Cmd + I`) | **导入文件** | 快速调出文件选择面板，导入 `.txt` / `.epub` / `.srt` / `.ass` |
| **`⌘ + E`** (`Cmd + E`) | **开始生成导出** | 一键启动当前模式的批量合成（音频 / M4B / 字幕视频） |
| **`⌘ + .`** (`Cmd + .`) | **取消生成** | 正在导出时立刻中止合成流水线并自动清理临时缓存 |
| **`⌘ + R`** (`Cmd + R`) | **重新解析当前文件** | 调整智能修标点/拆长句开关后，快速重新解析当前书籍 |
| **`⇧ + ⌘ + C`** (`Shift + Cmd + C`) | **复制全部运行日志** | 一键将完整的毫秒级性能与分句日志拷贝至剪贴板 |
| **`⌘ + K`** (`Cmd + K`) | **清空运行日志** | 清理当前日志控制台面板 |

---

## 核心功能

- **丰富输入格式**：`.txt` / `.epub`（电子书）、`.srt` / `.ass` / `.ssa`（字幕）
- **四种导出模式**：
  - **字幕视频（默认）**：多核并发流水线，当前句锚定画面中心，历史字幕平滑向上淡出，未来字幕逐行渐显；
  - **M4B 有声书**：AudioToolbox 硬件 AAC 高速压缩，体积缩减 96%，自动嵌入精准章节时间戳；
  - **无损音频**：`AVSpeechSynthesizer` 离线抓轨，44.1 kHz PCM 毫秒级时间戳，连带写出 `.srt` 与 `.ass`；
  - **SRT 字幕草稿**：瞬时生成带字数与语速时间轴的字幕草稿。
- **视觉美学与视频动效**：
  - **字级卡拉OK点亮动效**：CoreText 逐行字符加权排版，高亮发光色随朗读节奏逐字逐行平滑点亮（彻底告别多行同时亮起）；
  - **多画幅自适应**：**9:16 竖屏（默认）**、**16:9 横屏**、1:1 正方形、3:4、4:3，分辨率支持 480p / 720p / 1080p / 4K；
  - **编解码与帧率**：**HEVC / H.265（默认硬件加速）** 与 H.264，帧率支持 24fps（电影质感）/ 25 / 30 / 60fps；
  - **排版字体与主题**：支持宋体、楷体、苹方、系统默认等中文典雅字体；支持极简纯黑、深空微光、炭黑雅致、午夜暗韵等主题背景；
  - **声波可视化组件**：基于真实语音 RMS 能量驱动的平滑跳动声波律动柱；
  - **自定义水印**：支持文本/图片 9 宫格定位、透明度与等比缩放。
- **音频处理与混音（DSP）**：
  - **大自然音效与背景音乐（BGM）混音**：支持自选 MP3/WAV/M4A，或开箱即用的 **7 大内置自然音效与轻音乐**（海浪波涛、山间小溪、沉浸雨声、林间微风、暗噪音、平衡粉噪、舒缓和弦氛围乐）；
  - **智能侧链避让压限（Smart Audio Ducking）**：Accelerate (vDSP) 实时识别人声能量包络，朗读时 BGM 自动压低避让，句间停顿与章节过渡自然回升；
  - **自适应停顿呼吸感**：支持 0× ~ 2× 停顿倍率（默认 1.4×），段末与分句呼吸感自然流畅。
- **全球顶级 AI 语音引擎架构**：
  - **Kokoro-82M 本地神经模型（默认）**：完全本地离线的顶级神经网络语音模型，媲美 ElevenLabs，0 网络依赖，单次可稳定畅读几十小时；
  - **微软广播级 Neural**：48kHz 广播级神经原声（云希、Christopher、晓晓等），免 API Key；
  - **自定义 API 接口**：一键兼容 OpenAI `tts-1-hd`、ElevenLabs、CosyVoice、ChatTTS 及本地 GPU 推理服务。
- **两条链路完全解耦**：字幕输入可**附带已有音频（wav/m4a/mp3）直接渲染视频，完全跳过 TTS**。

---

## 构建与运行

```bash
./build.sh              # 编译 → 打包 .app → 签名 → 启动
./build.sh --no-launch  # 仅打包不启动
swift run BookStream --selftest        # 无头端到端全链路自检
swift run BookStream --parse <file>    # 解析校验（txt/epub/srt/ass/ssa）
```

要求：macOS 13+，Xcode Command Line Tools（Swift 6）。

## 工程结构

```
Package.swift                     SPM 清单（macOS 13+，Swift 6 语言模式）
Sources/BookStream/
  Models.swift                    数据模型 + TXT/EPUB/SRT/ASS 解析 + 智能标点修复 + 分句
  AudioEngine.swift               TTS 离线抓轨 + BGM 侧链压限混音 + M4B 硬件 AAC 压缩
  KokoroTTS.swift                 Kokoro-82M 本地顶级神经模型批处理引擎
  EdgeTTS.swift                   微软 Edge-TTS 广播级神经语音引擎
  CustomAPITTS.swift              自定义 OpenAI / 11Labs / CosyVoice API 客户端
  VideoSynthesizer.swift          逐行卡拉OK排版 + 多画幅/HEVC/字体/主题/声波 + AVAssetWriter 双轨混流
  ContentView.swift               SwiftUI 原生界面（快捷键/调色盘/音量滑块/日志/回放预览）
  BookStreamApp.swift             @main 入口（全局快捷键与原生菜单栏绑定）
  SelfTest.swift                  无头端到端自动化全链路自检
Scripts/make_icon.swift           应用图标生成器（CoreGraphics 绘制 → icns）
Resources/AppIcon.icns            应用图标
build.sh                          一键构建打包签名启动
docs/ARCHITECTURE.md              架构与时钟对齐方案
books/odyssey.txt                 示例书籍
```

## 快速体验

1. `./build.sh --no-launch`
2. 打开 `dist/BookStream.app`，按 **`⌘ + I`** 选择书籍或把 `books/odyssey.txt` 拖入左侧面板
3. 选择声音与语速，选择背景音乐，按 **`⌘ + E`** 一键开始生成！
