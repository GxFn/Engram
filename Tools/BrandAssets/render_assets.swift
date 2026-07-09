import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func writePNG(_ ctx: CGContext, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(name)")
}

/// A 4-point sparkle with sharply concave spikes (the classic ✨ shine).
func sparklePath(center c: CGPoint, radius R: CGFloat, waist: CGFloat) -> CGPath {
    let d = R * waist * 0.7071
    let up = CGPoint(x: c.x, y: c.y + R), rt = CGPoint(x: c.x + R, y: c.y)
    let dn = CGPoint(x: c.x, y: c.y - R), lf = CGPoint(x: c.x - R, y: c.y)
    let p = CGMutablePath()
    p.move(to: up)
    p.addQuadCurve(to: rt, control: CGPoint(x: c.x + d, y: c.y + d))
    p.addQuadCurve(to: dn, control: CGPoint(x: c.x + d, y: c.y - d))
    p.addQuadCurve(to: lf, control: CGPoint(x: c.x - d, y: c.y - d))
    p.addQuadCurve(to: up, control: CGPoint(x: c.x - d, y: c.y + d))
    p.closeSubpath()
    return p
}

func fillGradient(_ ctx: CGContext, rect: CGRect, from: CGColor, to: CGColor, start: CGPoint, end: CGPoint) {
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [from, to] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addRect(rect); ctx.clip()
    ctx.drawLinearGradient(gradient, start: start, end: end, options: [])
    ctx.restoreGState()
}

func radialGlow(_ ctx: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    let clear = color.copy(alpha: 0)!
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color, clear] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

/// Big sparkle + a small companion sparkle, white with a soft glow. `s` is the canvas size.
func drawMark(_ ctx: CGContext, size s: CGFloat, glowAlpha: Double) {
    let big = CGPoint(x: s * 0.5, y: s * 0.52)
    let bigR = s * 0.30

    // Soft glow halo behind the mark.
    ctx.saveGState()
    radialGlow(ctx, center: big, radius: bigR * 1.9, color: rgb(226, 214, 255, glowAlpha))
    ctx.restoreGState()

    // Big sparkle with a subtle top→bottom white gradient + outer glow.
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.05, color: rgb(140, 90, 240, 0.55))
    ctx.addPath(sparklePath(center: big, radius: bigR, waist: 0.14))
    ctx.clip()
    fillGradient(ctx, rect: CGRect(x: big.x - bigR, y: big.y - bigR, width: bigR * 2, height: bigR * 2),
                 from: rgb(255, 255, 255), to: rgb(232, 223, 255),
                 start: CGPoint(x: big.x, y: big.y + bigR), end: CGPoint(x: big.x, y: big.y - bigR))
    ctx.restoreGState()

    // Small companion sparkle, upper-right.
    let small = CGPoint(x: s * 0.72, y: s * 0.74)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: s * 0.03, color: rgb(140, 90, 240, 0.5))
    ctx.addPath(sparklePath(center: small, radius: s * 0.10, waist: 0.16))
    ctx.setFillColor(rgb(255, 255, 255))
    ctx.fillPath()
    ctx.restoreGState()
}

func drawIcon(dark: Bool) {
    let s = 1024
    let ctx = makeContext(width: s, height: s)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    let (from, to) = dark
        ? (rgb(58, 34, 112), rgb(28, 16, 56))     // deep violet
        : (rgb(130, 80, 230), rgb(78, 40, 168))   // vivid violet
    fillGradient(ctx, rect: rect, from: from, to: to,
                 start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0))
    drawMark(ctx, size: CGFloat(s), glowAlpha: dark ? 0.22 : 0.34)
    writePNG(ctx, dark ? "icon-1024-dark.png" : "icon-1024.png")
}

func drawWordmark(_ ctx: CGContext, _ text: String, centerX: CGFloat, baselineY: CGFloat, fontSize: CGFloat, color: CGColor) {
    let font = CTFontCreateWithName("AvenirNext-DemiBold" as CFString, fontSize, nil)
    let attrs: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
        kCTKernAttributeName: fontSize * 0.02,
    ]
    let attr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
    let line = CTLineCreateWithAttributedString(attr)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textMatrix = .identity
    ctx.textPosition = CGPoint(x: centerX - bounds.width / 2 - bounds.minX, y: baselineY)
    CTLineDraw(line, ctx)
}

func drawLaunchLogo() {
    let s = 1080
    let ctx = makeContext(width: s, height: s) // transparent canvas; bg comes from UIColorName
    let S = CGFloat(s)

    // Tight, centered lockup: mark above, wordmark directly beneath.
    let big = CGPoint(x: S * 0.5, y: S * 0.60)
    let bigR = S * 0.195
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.03, color: rgb(150, 100, 245, 0.5))
    ctx.addPath(sparklePath(center: big, radius: bigR, waist: 0.14)); ctx.clip()
    fillGradient(ctx, rect: CGRect(x: big.x - bigR, y: big.y - bigR, width: bigR * 2, height: bigR * 2),
                 from: rgb(255, 255, 255), to: rgb(236, 227, 255),
                 start: CGPoint(x: big.x, y: big.y + bigR), end: CGPoint(x: big.x, y: big.y - bigR))
    ctx.restoreGState()

    let small = CGPoint(x: S * 0.655, y: S * 0.72)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: S * 0.02, color: rgb(150, 100, 245, 0.5))
    ctx.addPath(sparklePath(center: small, radius: S * 0.062, waist: 0.16))
    ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
    ctx.restoreGState()

    drawWordmark(ctx, "Engram", centerX: S / 2, baselineY: S * 0.30,
                 fontSize: S * 0.105, color: rgb(237, 231, 255))
    writePNG(ctx, "LaunchLogo.png")
}

drawIcon(dark: false)
drawIcon(dark: true)
drawLaunchLogo()
