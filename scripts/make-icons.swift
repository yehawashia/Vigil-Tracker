// Builds every app icon from Resources/Logo/logo-source.jpg (a photo of the drawn logo).
//   swift scripts/make-icons.swift
// 1. Lifts the ink off the paper (divides out uneven lighting with a heavy blur), crops to the drawing.
// 2. Writes Resources/Logo/logo-mark.png (ink on transparent), the macOS iconset, and the iOS app icon.
import AppKit
import CoreImage

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let src = root.appendingPathComponent("Resources/Logo/logo-source.jpg")
guard let input = CIImage(contentsOf: src) else { fatalError("missing \(src.path)") }
let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
let extent = input.extent

// Paper estimate: heavy blur (lines are thin, so this is ~ the paper's lighting).
let gray = input.applyingFilter("CIPhotoEffectMono")
let paper = gray.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": 28]).cropped(to: extent)
guard let g = ctx.createCGImage(gray, from: extent), let p = ctx.createCGImage(paper, from: extent) else { fatalError() }

func pixels(_ img: CGImage) -> [UInt8] {
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let c = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return buf
}
let W = g.width, H = g.height
let gp = pixels(g), pp = pixels(p)

// Ink alpha = how much darker than the local paper, with a soft knee so faint pencil stays faint.
var alpha = [Float](repeating: 0, count: W * H)
var minX = W, minY = H, maxX = 0, maxY = 0
for i in 0..<(W * H) {
    let lum = Float(gp[i * 4]) / 255, pap = max(0.2, Float(pp[i * 4]) / 255)
    var a = (pap - lum) / (pap * 0.72)
    a = max(0, min(1, (a - 0.06) / 0.94))
    a = pow(a, 0.85)
    alpha[i] = a
    if a > 0.35 {
        let x = i % W, y = i / W
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
// Square crop around the drawing, with breathing room for the construction marks.
let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
let side = Int(Double(max(maxX - minX, maxY - minY)) * 1.06)
let x0 = max(0, cx - side / 2), y0 = max(0, cy - side / 2)
let S = min(side, W - x0, H - y0)

func mark(ink: (UInt8, UInt8, UInt8)) -> CGImage {
    var out = [UInt8](repeating: 0, count: S * S * 4)
    for y in 0..<S { for x in 0..<S {
        let a = alpha[(y0 + y) * W + (x0 + x)]
        let o = (y * S + x) * 4
        out[o] = UInt8(Float(ink.0) * a); out[o + 1] = UInt8(Float(ink.1) * a); out[o + 2] = UInt8(Float(ink.2) * a); out[o + 3] = UInt8(255 * a)
    } }
    let provider = CGDataProvider(data: Data(out) as CFData)!
    return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: S * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}

func render(size: Int, _ draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let c = NSGraphicsContext.current!.cgContext
    c.interpolationQuality = .high
    draw(c)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}
func save(_ rep: NSBitmapImageRep, _ path: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: url)
}
func rgb(_ h: UInt32) -> CGColor { CGColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1) }

let ink = mark(ink: (0x16, 0x16, 0x16))
save(render(size: 1024) { c in c.draw(ink, in: CGRect(x: 0, y: 0, width: 1024, height: 1024)) }, "Resources/Logo/logo-mark.png")

// macOS: rounded "paper" tile with Apple's icon margins (824 of 1024), a hairline edge and soft shadow.
let mac = render(size: 1024) { c in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.28))
    c.addPath(path); c.setFillColor(rgb(0xEEECE8)); c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    c.addPath(path); c.setStrokeColor(CGColor(gray: 0, alpha: 0.10)); c.setLineWidth(2); c.strokePath()
    c.saveGState(); c.addPath(path); c.clip()
    c.draw(ink, in: tile.insetBy(dx: 70, dy: 70))
    c.restoreGState()
}
save(mac, "Resources/Logo/icon-macos-1024.png")

// iOS / iPadOS: full-bleed square (the system rounds the corners).
let ios = render(size: 1024) { c in
    c.setFillColor(rgb(0xEEECE8)); c.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    c.draw(ink, in: CGRect(x: 120, y: 120, width: 784, height: 784))
}
save(ios, "iOS/App/Assets.xcassets/AppIcon.appiconset/icon-1024.png")
// Small sizes (16–64 px): thicken the ink (dilate + boost) and enlarge it, so the shape survives downscaling.
var bold = [Float](repeating: 0, count: S * S)
let r = 2
for y in 0..<S { for x in 0..<S {
    var m: Float = 0
    for dy in stride(from: -r, through: r, by: 1) {
        let yy = y0 + y + dy; if yy < 0 || yy >= H { continue }
        for dx in stride(from: -r, through: r, by: 1) {
            let xx = x0 + x + dx; if xx < 0 || xx >= W { continue }
            m = max(m, alpha[yy * W + xx])
        }
    }
    bold[y * S + x] = min(1, m * 1.15)
} }
let boldInk: CGImage = {
    var out = [UInt8](repeating: 0, count: S * S * 4)
    for i in 0..<(S * S) { let a = bold[i]; out[i * 4] = UInt8(0x16 * a); out[i * 4 + 1] = UInt8(0x16 * a); out[i * 4 + 2] = UInt8(0x16 * a); out[i * 4 + 3] = UInt8(255 * a) }
    return CGImage(width: S, height: S, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: S * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                   provider: CGDataProvider(data: Data(out) as CFData)!, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
}()
let macSmall = render(size: 1024) { c in
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    c.addPath(path); c.setFillColor(rgb(0xEEECE8)); c.fillPath()
    c.addPath(path); c.setStrokeColor(CGColor(gray: 0, alpha: 0.18)); c.setLineWidth(10); c.strokePath()
    c.saveGState(); c.addPath(path); c.clip()
    c.draw(boldInk, in: tile.insetBy(dx: 30, dy: 30))
    c.restoreGState()
}
save(macSmall, "Resources/Logo/icon-macos-small-1024.png")

print("crop \(S)px at (\(x0), \(y0)); wrote logo-mark, macOS and iOS icons")
