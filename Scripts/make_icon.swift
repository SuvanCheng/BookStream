#!/usr/bin/env swift
// BookStream 应用图标生成器（纯本地 CoreGraphics/AppKit，无第三方依赖）
// 用法: swift Scripts/make_icon.swift
// 产出: Resources/AppIcon.iconset/*.png 与 Resources/AppIcon.icns，以及预览图 AppIcon-preview.png

import AppKit
import Foundation

// MARK: - 绘制（1024 设计坐标系，y 向上）

func drawIcon(size: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let S = CGFloat(size) / 1024.0 // 缩放因子
    func P(_ v: CGFloat) -> CGFloat { v * S }

    // ---- 1. 圆角矩形背景（squircle）----
    let bgRect = CGRect(x: P(40), y: P(40), width: P(944), height: P(944))
    let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: P(225), yRadius: P(225))
    let bgGradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.21, green: 0.29, blue: 0.47, alpha: 1.0),
        NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.16, alpha: 1.0),
    ])!
    bgGradient.draw(in: bgPath, angle: -90)

    // ---- 2. 打开的书（暖纸色）----
    let paper = NSColor(calibratedRed: 0.95, green: 0.92, blue: 0.86, alpha: 1.0)
    let paperDark = NSColor(calibratedRed: 0.55, green: 0.48, blue: 0.36, alpha: 1.0)

    func pagePath(_ mirror: Bool) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: P(512), y: P(322)))
        path.curve(to: NSPoint(x: P(512), y: P(628)),
                   controlPoint1: NSPoint(x: mirror ? P(479) : P(545), y: P(410)),
                   controlPoint2: NSPoint(x: mirror ? P(479) : P(545), y: P(540)))
        let outerX: CGFloat = mirror ? 784 : 240
        let c1x: CGFloat = mirror ? 724 : 300
        let c2x: CGFloat = mirror ? 819 : 205
        path.curve(to: NSPoint(x: P(outerX), y: P(596)),
                   controlPoint1: NSPoint(x: mirror ? P(609) : P(415), y: P(610)),
                   controlPoint2: NSPoint(x: P(c1x), y: P(615)))
        path.curve(to: NSPoint(x: P(outerX), y: P(352)),
                   controlPoint1: NSPoint(x: P(c2x), y: P(560)),
                   controlPoint2: NSPoint(x: P(c2x), y: P(390)))
        path.close()
        return path
    }

    // 左页 + 右页
    let left = pagePath(false)
    let right = pagePath(true)
    paper.setFill()
    left.fill()
    right.fill()

    // 页面向外侧的阴影渐变（增强立体感）
    let shade = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.0),
        NSColor.black.withAlphaComponent(0.16),
    ])!
    let shadeLeft = NSGradient(colors: [
        NSColor.black.withAlphaComponent(0.16),
        NSColor.black.withAlphaComponent(0.0),
    ])!
    shade.draw(in: left, angle: 0)
    shadeLeft.draw(in: right, angle: 0)

    // 书页文字线
    NSColor(calibratedRed: 0.42, green: 0.35, blue: 0.24, alpha: 0.5).setFill()
    func textLines(x0: CGFloat, x1: CGFloat, top: CGFloat, gap: CGFloat, count: Int) {
        for i in 0..<count {
            let t = top - CGFloat(i) * gap
            let len = x1 - x0 - CGFloat(i) * (x1 - x0) * 0.10
            let lineRect = CGRect(x: P(x0), y: P(t), width: P(len), height: P(16))
            NSBezierPath(roundedRect: lineRect, xRadius: P(8), yRadius: P(8)).fill()
        }
    }
    textLines(x0: 300, x1: 476, top: 552, gap: 68, count: 3)
    textLines(x0: 548, x1: 724, top: 552, gap: 68, count: 3)

    // 书脊阴影
    let spine = NSBezierPath()
    spine.move(to: NSPoint(x: P(512), y: P(322)))
    spine.curve(to: NSPoint(x: P(512), y: P(628)),
                controlPoint1: NSPoint(x: P(530), y: P(410)),
                controlPoint2: NSPoint(x: P(530), y: P(540)))
    spine.lineWidth = P(10)
    NSColor.black.withAlphaComponent(0.30).setStroke()
    spine.stroke()

    // 书脊顶部的橙色书签
    let ribbon = NSBezierPath()
    ribbon.move(to: NSPoint(x: P(494), y: P(616)))
    ribbon.line(to: NSPoint(x: P(530), y: P(616)))
    ribbon.line(to: NSPoint(x: P(512), y: P(696)))
    ribbon.close()
    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.0, alpha: 1.0).setFill()
    ribbon.fill()

    // ---- 3. 音频波形（橘色，位于书下方）----
    let barHeights: [CGFloat] = [70, 120, 170, 200, 170, 120, 70]
    let barWidth = P(44)
    let gap = P(34)
    let totalW = CGFloat(barHeights.count) * barWidth + CGFloat(barHeights.count - 1) * gap
    let startX = (1024 - totalW) / 2
    let baseY = P(110)
    let waveGradient = NSGradient(colors: [
        NSColor(calibratedRed: 1.0, green: 0.72, blue: 0.28, alpha: 1.0),
        NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.0, alpha: 1.0),
    ])!
    for (i, h) in barHeights.enumerated() {
        let x = startX + CGFloat(i) * (barWidth + gap)
        let barRect = CGRect(x: P(x), y: P(baseY), width: barWidth, height: P(h))
        let barPath = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)
        waveGradient.draw(in: barPath, angle: 90)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - 输出

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconsetDir = root.appendingPathComponent("Resources/AppIcon.iconset")
try? fm.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for item in sizes {
    let rep = drawIcon(size: item.px)
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: iconsetDir.appendingPathComponent(item.name))
    print("  wrote \(item.name) (\(item.px)x\(item.px))")
}

// 预览图
let preview = drawIcon(size: 1024)
try preview.representation(using: .png, properties: [:])!
    .write(to: root.appendingPathComponent("Resources/AppIcon-preview.png"))

// icns
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetDir.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    print("iconutil 失败"); exit(1)
}
print("OK: Resources/AppIcon.icns 已生成")
