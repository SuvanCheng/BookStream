# v1.1.1 回归修复报告

针对 v1.1 提交带来的三个回归，已在当前工作树完成修复、编译通过（debug + release），
并通过自检 / 针对性实测验证。

---

## 问题 1：滚动字幕不丝滑 + 重叠 + 变速感明显

**根因**：v1.1 的「软锚定/无感变速」滚动逻辑引入了逐帧可变的滚动速度（历史行下滚、
未来行上挤），速度不是常数导致观感卡顿，且变速收敛过程中行间距离触发的间距钳制与
变速叠加，偶发出现重叠。

**修复**：把 `VideoSynthesizer.drawRollingCaptions` 整体还原为 v1.0 已被用户验证丝滑的实现：
- 恒定速度滚动（`speed = scrollSpeed * scale`，不再随帧可变）。
- 当前朗读句锚定画面中心并高亮，整句静止；历史行以恒定速度上滚淡出、未来行以同速接近。
- 所有行按「行高均值 + 间隙」间距约束（`spacing(a,b) = (ha+hb)/2 + minGap`），配合
  `max`/`min` 钳制，结构上杜绝重叠。
- 排版复用手账 `layoutCache`（按 id+高亮双键），跨帧零重建。

**验证**：`swift build`、`swift build -c release` 均通过；`--selftest` 渲染 343 帧成功。

---

## 问题 2：水印图片上下颠倒 / 可能镜像 + 随字幕长短抖动

**根因（方向）**：`drawWatermark` 对 CGImage 之前使用了 `translateBy+scaleBy(-1)` 翻转。
本视频上下文的位图 CGBitmapContext 是「非翻转（32BGRA premultipliedFirst 小端）」，此时追加
scale(-1) 会把图片旋转 180°（上下颠倒 + 左右镜像）——与文字 CTFrameDraw 已知的翻转陷阱同类。

**实测证据**：用与 `makeFrame` 完全一致的位图格式（real base buffer、
`premultipliedFirst.rawValue | byteOrder32Little`）写了独立探针 `/tmp/wmprobe/main.swift`，
对同一张上下有红/绿不对称色的测试图分别测两种画法在帧缓冲里的行序：

```
测试图：内存行0=红（图片上方）
OLD FLIP (translate+scale -1)：帧行 0..39=绿、200..239=红  → 图片上方落在屏幕底部（颠倒）
PLAIN draw（直接 draw）      ：帧行 0..39=红、200..239=绿  → 图片上方落在屏幕顶部（正向）✓
```

**修复**：`drawWatermark` 改为直接 `ctx.draw(image, in: rect)`（代码中的注释也已同步说明）。
探针证明该画法在非翻转位图上下文中保持图片正向，不颠倒、不镜像。

**根因（抖动）**：v1.1 中水印定位曾与某些布局量耦合；现 `drawWatermark` / `watermarkRectOrigin`
完全只依赖 `wm.*` 与画布尺寸，与字幕行数/宽度零耦合——每帧水印位置与像素确定，不受字幕长短影响。

**验证**：方向性由 `/tmp/wmprobe` 探针实证；build + selftest 通过。

---

## 问题 3：语气停顿感 0.0x→2.0x 几乎无效果

**机制本身已证明有效**：`AudioEngine.renderBook` 的同步分支用 `writeSilence` 把
`pauseAfter * pauseScale` 的静音写入 WAV，并把对应视频 endFrame 顺延。自检客观证据：
`PAUSE OK: 0×停顿 10.75s → 2×停顿 12.15s`（同一个句子，仅 pauseScale 从 0 变 2，
时长 +1.40s = 0.7s 基线 × 2，完全吻合）。

**用户觉得不明显的原因**：基线停顿太短（普通句 0.25s、段末 0.7s），即使 2× 也只有
0.50s / 1.40s，人耳感受弱。

**修复**：`TextProcessor.splitSentencesWithPauses` 提升基线停顿：
- 普通句末 0.25s → **0.4s**
- 空行后的段落末尾 0.7s → **1.0s**

配合「停顿感」滑块（0...2，步进 0.1），0.4s×2=0.8s、1.0s×2=2.0s，停顿清晰可感。
`pauseScale` 已确认正确贯通两条导出路径（`.audioSRT` 与 `.video` 的 `renderBook` 调用，
见 `ContentView.swift` 行 617 / 645）。

**验证**：`--selftest` 打印 `PAUSE OK: 0×停顿 10.75s → 2×停顿 12.15s`，说明滑块数值
确实改变合成音频时长；文档注释已同步更新。

---

## 构建与验证结论

```
swift build                       → Build complete!
swift build -c release            → Build complete! (.build/release/BookStream, 1.78 MB)
swift run -c release BookStream --selftest
  → TTS OK / PAUSE OK (10.75s→12.15s) / AI VOICE OK / OVERFLOW OK×2 / SRT OK / ASS OK /
    VIDEO OK (343 帧) / DECOUPLED OK  /  SELFTEST PASSED
```

改动文件：
- `Sources/BookStream/VideoSynthesizer.swift` —— 还原 v1.0 恒定速度滚动字幕；水印改用直接 draw（正向、不镜像）；水印与字幕、进度条解耦。
- `Sources/BookStream/Models.swift` —— 提升停顿基线（0.25→0.4s，0.7→1.0s）并更新文档注释。
- `FIXES-v1.1.1.md` —— 本报告。