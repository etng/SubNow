// make_icon.swift — 生成 SubNow 应用图标（A1 条纹闪电）与菜单栏模板图标
// 用法: swift scripts/make_icon.swift <输出目录>
// 产物: AppIcon.icns、menubar-18.png、menubar-36.png（模板图，黑+透明）
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

// 设计坐标：1024 画布（与 SVG 定稿 256 坐标 ×4 对应）
func makeContext(_ size: Int) -> CGContext {
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: sRGB,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)  // 翻转到左上原点，与设计坐标一致
    return ctx
}

let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let gold = CGColor(srgbRed: 0.984, green: 0.749, blue: 0.141, alpha: 1)  // #FBBF24

func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// A1 条纹闪电应用图标（设计空间 1024）
func drawAppIcon(in ctx: CGContext, canvas: CGFloat) {
    let s = canvas / 1024
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)

    // 背景 squircle + 对角渐变
    let bgRect = CGRect(x: 64, y: 64, width: 896, height: 896)
    ctx.addPath(rounded(bgRect, 208))
    ctx.clip()
    let grad = CGGradient(colorsSpace: sRGB, colors: [
        CGColor(srgbRed: 0.388, green: 0.400, blue: 0.945, alpha: 1),  // #6366F1
        CGColor(srgbRed: 0.486, green: 0.227, blue: 0.929, alpha: 1),  // #7C3AED
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 64, y: 64), end: CGPoint(x: 960, y: 960), options: [])

    // 内侧高光描边
    ctx.addPath(rounded(CGRect(x: 80, y: 80, width: 864, height: 864), 192))
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.setLineWidth(8)
    ctx.strokePath()

    // 闪电剪裁 + 声波条
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: 564, y: 176))
    bolt.addLine(to: CGPoint(x: 408, y: 488))
    bolt.addLine(to: CGPoint(x: 504, y: 488))
    bolt.addLine(to: CGPoint(x: 444, y: 688))
    bolt.addLine(to: CGPoint(x: 648, y: 376))
    bolt.addLine(to: CGPoint(x: 544, y: 376))
    bolt.addLine(to: CGPoint(x: 616, y: 176))
    bolt.closeSubpath()

    ctx.saveGState()
    ctx.addPath(bolt)
    ctx.clip()
    let heights: [CGFloat] = [264, 432, 336, 464, 288, 392]
    let xs: [CGFloat] = [392, 438, 484, 530, 576, 622]
    ctx.setFillColor(white)
    for (x, h) in zip(xs, heights) {
        ctx.addPath(rounded(CGRect(x: x, y: 432 - h / 2, width: 36, height: h), 18))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // 双行字幕条：白色长条 + 金色短条
    ctx.setFillColor(white)
    ctx.addPath(rounded(CGRect(x: 280, y: 760, width: 464, height: 72), 36))
    ctx.fillPath()
    ctx.setFillColor(gold)
    ctx.addPath(rounded(CGRect(x: 376, y: 864, width: 272, height: 60), 30))
    ctx.fillPath()

    ctx.restoreGState()
}

/// 菜单栏模板字形（设计空间 24 → 输出 18/36px）：双字幕条
func drawMenuBarGlyph(in ctx: CGContext, canvas: CGFloat) {
    let s = canvas / 24
    ctx.saveGState()
    ctx.scaleBy(x: s, y: s)
    ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
    ctx.addPath(rounded(CGRect(x: 3, y: 8, width: 18, height: 5), 2.5))
    ctx.fillPath()
    ctx.addPath(rounded(CGRect(x: 7, y: 15.5, width: 10, height: 4), 2))
    ctx.fillPath()
    ctx.restoreGState()
}

func writePNG(_ ctx: CGContext, to url: URL) throws {
    let img = ctx.makeImage()!
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, img, nil)
    guard CGImageDestinationFinalize(dest) else { throw NSError(domain: "icon", code: 1) }
}

// 应用图标 iconset → icns
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let spec: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, px) in spec {
    let ctx = makeContext(px)
    drawAppIcon(in: ctx, canvas: CGFloat(px))
    try writePNG(ctx, to: iconset.appendingPathComponent(name))
}

// 菜单栏模板图（18pt: 1x/2x）
for (name, px) in [("menubar-18.png", 18), ("menubar-36.png", 36)] {
    let ctx = makeContext(px)
    drawMenuBarGlyph(in: ctx, canvas: CGFloat(px))
    try writePNG(ctx, to: URL(fileURLWithPath: outDir).appendingPathComponent(name))
}

print("✓ 图标已生成: \(outDir)/AppIcon.iconset + menubar-18/36.png")
