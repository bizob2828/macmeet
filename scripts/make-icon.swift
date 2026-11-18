// Renders the MacMeet app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
//
// The artwork is a Meet-style camera drawn on a macOS icon tile, with "mM" in the camera body.
// Everything is drawn in a 1024×1024 coordinate space and rendered at each iconset size.

import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32) -> CGColor {
  CGColor(
    srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
    green: CGFloat((hex >> 8) & 0xFF) / 255,
    blue: CGFloat(hex & 0xFF) / 255,
    alpha: 1
  )
}

let red = color(0xEA4335)
let yellow = color(0xFFBA00)
let green = color(0x00AC47)
let darkGreen = color(0x00832D)
let blue = color(0x2684FC)
let ink = color(0x3C4043)

func drawIcon(in ctx: CGContext) {
  // Tile, inset to Apple's icon grid so the shadow fits inside the canvas.
  let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
  let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

  ctx.saveGState()
  ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: CGColor(gray: 0, alpha: 0.3))
  ctx.addPath(tilePath)
  ctx.setFillColor(.white)
  ctx.fillPath()
  ctx.restoreGState()

  ctx.saveGState()
  ctx.addPath(tilePath)
  ctx.clip()
  let gradient = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
    colors: [CGColor(gray: 1, alpha: 1), color(0xE8EAED)] as CFArray,
    locations: [0, 1]
  )!
  ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
  ctx.restoreGState()

  // Camera body: a colored frame around a white panel holding the lettering.
  let body = CGRect(x: 176, y: 302, width: 500, height: 420)
  let band: CGFloat = 64
  let bodyPath = CGPath(roundedRect: body, cornerWidth: 56, cornerHeight: 56, transform: nil)

  ctx.saveGState()
  ctx.addPath(bodyPath)
  ctx.clip()
  ctx.setFillColor(green)
  ctx.fill(body)
  ctx.setFillColor(yellow)
  ctx.fill(CGRect(x: body.minX + band, y: body.maxY - band, width: body.width - band, height: band))
  ctx.setFillColor(blue)
  ctx.fill(CGRect(x: body.minX, y: body.minY + band, width: band, height: body.height - band * 2))
  ctx.setFillColor(red)
  ctx.fill(CGRect(x: body.minX, y: body.maxY - band, width: band, height: band))
  ctx.restoreGState()

  let panel = body.insetBy(dx: band, dy: band)
  ctx.addPath(CGPath(roundedRect: panel, cornerWidth: 16, cornerHeight: 16, transform: nil))
  ctx.setFillColor(.white)
  ctx.fillPath()

  // Lens: a flared trapezoid on the right side of the body.
  let lens = CGMutablePath()
  lens.move(to: CGPoint(x: body.maxX - 2, y: body.midY - 90))
  lens.addLine(to: CGPoint(x: 848, y: body.minY + 20))
  lens.addLine(to: CGPoint(x: 848, y: body.maxY - 20))
  lens.addLine(to: CGPoint(x: body.maxX - 2, y: body.midY + 90))
  lens.closeSubpath()
  ctx.saveGState()
  ctx.addPath(lens)
  ctx.setLineJoin(.round)
  ctx.setLineWidth(36)
  ctx.setStrokeColor(darkGreen)
  ctx.setFillColor(darkGreen)
  ctx.drawPath(using: .fillStroke)
  ctx.restoreGState()

  drawLettering("mM", in: panel.insetBy(dx: 18, dy: 18), ctx: ctx)
}

/// Draws the text as large as fits in the rect, centered on its glyph bounds.
func drawLettering(_ text: String, in rect: CGRect, ctx: CGContext) {
  func font(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    let rounded = base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor
    return NSFont(descriptor: rounded, size: size) ?? base
  }

  func line(_ size: CGFloat) -> CTLine {
    let string = NSAttributedString(string: text, attributes: [
      .font: font(size),
      .foregroundColor: NSColor(cgColor: ink)!,
      .kern: -size * 0.02,
    ])
    return CTLineCreateWithAttributedString(string)
  }

  var size: CGFloat = 400
  var bounds = CTLineGetImageBounds(line(size), ctx)
  let scale = min(rect.width / bounds.width, rect.height / bounds.height)
  size *= scale
  let fitted = line(size)
  bounds = CTLineGetImageBounds(fitted, ctx)

  ctx.textPosition = CGPoint(x: rect.midX - bounds.midX, y: rect.midY - bounds.midY)
  CTLineDraw(fitted, ctx)
}

func renderPNG(pixels: Int, to url: URL) throws {
  let ctx = CGContext(
    data: nil,
    width: pixels,
    height: pixels,
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
  )!
  ctx.interpolationQuality = .high
  ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
  drawIcon(in: ctx)

  let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
  try rep.representation(using: .png, properties: [:])!.write(to: url)
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for points in [16, 32, 128, 256, 512] {
  try renderPNG(pixels: points, to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
  try renderPNG(pixels: points * 2, to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let output = root.appendingPathComponent("Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }

try renderPNG(pixels: 1024, to: root.appendingPathComponent("build/AppIcon-preview.png"))
print("Wrote \(output.path)")
