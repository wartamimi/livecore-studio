// CI check for the Title Designer: renders every template with its sample text through the real
// CoreText renderer, fails if one draws nothing, and writes a contact sheet
// (build/title-templates.png) that CI attaches to the release for a visual check.
//   swift run livecore-title-check
#if os(macOS)
import AppKit
import Foundation
import ImageIO
import LiveCoreCore
import LiveCoreEngine
import UniformTypeIdentifiers

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("title-check: FAIL: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

/// Fraction of pixels with any alpha.
func coverage(_ img: CGImage) -> Double {
    guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return 0 }
    let bpr = img.bytesPerRow
    var n = 0
    for y in 0..<img.height { for x in 0..<img.width where p[y * bpr + x * 4 + 3] > 0 { n += 1 } }
    return Double(n) / Double(img.width * img.height)
}

let cw = 640, ch = 360, cols = 3, label = 28
let all = TitleTemplate.allCases
let rows = (all.count + cols - 1) / cols
let sheetW = cols * cw, sheetH = rows * (ch + label)
guard let sheet = CGContext(data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
else { fail("no context") }
sheet.setFillColor(NSColor(white: 0.1, alpha: 1).cgColor)
sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

for (i, t) in all.enumerated() {
    let s = t.sample
    guard let img = TitleRenderer.image(t.defaultDesign, title: s.title, subtitle: s.subtitle, width: 1280, height: 720) else {
        fail("\(t.rawValue): no image")
    }
    let cov = coverage(img)
    guard cov > 0.002 else { fail("\(t.rawValue) draws nothing (\(cov))") }
    print("title-check: \(t.rawValue) \(String(format: "%.1f", cov * 100))% covered")
    let col = i % cols, row = i / cols
    let x = col * cw, y = sheetH - (row + 1) * (ch + label)
    // Grey "video" behind the title with a diagonal so transparency is visible.
    sheet.setFillColor(NSColor(calibratedRed: 0.32, green: 0.36, blue: 0.42, alpha: 1).cgColor)
    sheet.fill(CGRect(x: x, y: y, width: cw, height: ch))
    sheet.setFillColor(NSColor(calibratedRed: 0.45, green: 0.5, blue: 0.55, alpha: 1).cgColor)
    sheet.fill(CGRect(x: x, y: y, width: cw / 3, height: ch))
    sheet.draw(img, in: CGRect(x: x, y: y, width: cw, height: ch))
    let g = NSGraphicsContext(cgContext: sheet, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = g
    NSAttributedString(string: t.rawValue, attributes: [.font: NSFont.systemFont(ofSize: 16, weight: .medium),
                                                        .foregroundColor: NSColor.white])
        .draw(at: NSPoint(x: x + 8, y: y + ch + 5))
    NSGraphicsContext.restoreGraphicsState()
}

// Portrait canvas: every template must still draw.
for t in all {
    let s = t.sample
    guard let img = TitleRenderer.image(t.defaultDesign, title: s.title, subtitle: s.subtitle, width: 360, height: 640),
          coverage(img) > 0.001 else { fail("\(t.rawValue) draws nothing on a portrait canvas") }
}

try? FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
let url = URL(fileURLWithPath: "build/title-templates.png")
guard let out = sheet.makeImage(),
      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("no PNG") }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG not written") }
print("title-check: \(all.count) templates, sheet \(url.path)")
print("title-check: PASS")
#else
print("title-check: macOS only")
#endif
