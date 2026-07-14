#!/usr/bin/swift
// 程序化绘制应用图标：奶油色圆角底 + 两颗相互倾斜的咖啡豆。
// 用法: swift scripts/generate-icon.swift <iconset 输出目录>
// 之后用 iconutil -c icns <目录> -o Resources/AppIcon.icns 打包。
import AppKit

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: alpha)
}

// 所有尺寸均按 1024×1024 基准画布绘制后等比缩放，保证矢量清晰
let canvas: CGFloat = 1024

func drawBean(_ ctx: CGContext, center: CGPoint, width w: CGFloat, height h: CGFloat, angle: CGFloat) {
    ctx.saveGState()
    ctx.translateBy(x: center.x, y: center.y)
    ctx.rotate(by: angle)

    let body = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)

    // 底色 + 投影
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: color(0x3E2415, 0.45))
    ctx.setFillColor(color(0x5C3A21))
    ctx.fillEllipse(in: body)
    ctx.restoreGState()

    // 豆体斜向渐变
    ctx.saveGState()
    ctx.addEllipse(in: body)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0x7A4E2D), color(0x4A2A15)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: -w * 0.2, y: h / 2),
                           end: CGPoint(x: w * 0.2, y: -h / 2),
                           options: [])

    // 顶部柔和高光
    ctx.setFillColor(color(0xFFFFFF, 0.14))
    ctx.fillEllipse(in: CGRect(x: -w * 0.36, y: h * 0.06, width: w * 0.5, height: h * 0.34))
    ctx.restoreGState()

    // 中缝 S 曲线，用背景奶油色描边，读作豆子的裂缝
    let inset = h * 0.09
    let crease = CGMutablePath()
    crease.move(to: CGPoint(x: 0, y: -h / 2 + inset))
    crease.addCurve(to: CGPoint(x: 0, y: 0),
                    control1: CGPoint(x: w * 0.26, y: -h * 0.34),
                    control2: CGPoint(x: w * 0.26, y: -h * 0.08))
    crease.addCurve(to: CGPoint(x: 0, y: h / 2 - inset),
                    control1: CGPoint(x: -w * 0.26, y: h * 0.08),
                    control2: CGPoint(x: -w * 0.26, y: h * 0.34))
    ctx.saveGState()
    ctx.addEllipse(in: body.insetBy(dx: 6, dy: 6))
    ctx.clip()
    ctx.addPath(crease)
    ctx.setStrokeColor(color(0xF6E8D6))
    ctx.setLineWidth(w * 0.115)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState()
}

func drawIcon(_ ctx: CGContext, pixels: CGFloat) {
    ctx.scaleBy(x: pixels / canvas, y: pixels / canvas)

    // Big Sur 风格：圆角方形主体四周留出投影边距
    let bg = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 185, cornerHeight: 185, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.30))
    ctx.addPath(bgPath)
    ctx.setFillColor(color(0xF6E8D6))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: space,
                              colors: [color(0xFAF0E1), color(0xE9CFA8)] as CFArray,
                              locations: [0, 1])!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 512, y: 924),
                           end: CGPoint(x: 512, y: 100),
                           options: [])

    // 两颗咖啡豆：左小右大，底部大致对齐，顶部微微张开
    drawBean(ctx, center: CGPoint(x: 309, y: 470), width: 240, height: 375, angle: .pi * 20 / 180)
    drawBean(ctx, center: CGPoint(x: 672, y: 520), width: 320, height: 500, angle: -.pi * 20 / 180)
    ctx.restoreGState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    drawIcon(gctx.cgContext, pixels: CGFloat(pixels))
    gctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let data = renderPNG(pixels: variant.pixels)
    try data.write(to: URL(fileURLWithPath: "\(outDir)/\(variant.name).png"))
}
print("已生成 \(outDir)（\(variants.count) 个尺寸）")
