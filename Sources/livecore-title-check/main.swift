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
import LiveCoreServices
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

// 3D titles (0.59.0): halfway through the motion they still draw (perspective path).
for t in all where t.defaultDesign.active3D?.hasMotion == true {
    let s = t.sample
    guard let img = TitleRenderer.image(t.defaultDesign, title: s.title, subtitle: s.subtitle, width: 1280, height: 720, motion: 0.6),
          coverage(img) > 0.0005 else { fail("\(t.rawValue) draws nothing mid-motion") }
}
// Virtual sets (0.59.0): every studio fills the canvas.
for t in VirtualSetTemplate.allCases {
    for shot in VirtualSetShot.allCases {
        var d = t.defaultDesign
        d.shot = shot
        guard let img = VirtualSetRenderer.image(d, width: 640, height: 360, placeholder: false) else { fail("\(t.rawValue): no set image") }
        let cov = coverage(img)
        guard cov > 0.97 else { fail("virtual set \(t.rawValue) \(shot.rawValue) leaves holes (\(cov))") }
    }
    print("title-check: virtual set \(t.rawValue) OK")
}

try? FileManager.default.createDirectory(atPath: "build", withIntermediateDirectories: true)
let url = URL(fileURLWithPath: "build/title-templates.png")
guard let out = sheet.makeImage(),
      let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { fail("no PNG") }
CGImageDestinationAddImage(dest, out, nil)
guard CGImageDestinationFinalize(dest) else { fail("PNG not written") }
print("title-check: \(all.count) templates, sheet \(url.path)")
// .lctitle files (0.64.0): write and read back a 3D title and a running text with /usr/bin/zip + unzip.
do {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lctitle-check-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let t = TitlePackage(name: "Chrome 3D", title: "Speaker", subtitle: "Role", design: TitleTemplate.chrome3D.defaultDesign)
    let k = TitlePackage(name: "Gold band", ticker: TickerTemplate.gold3D.config(text: "Hello • World"))
    for p in [t, k] {
        let url = dir.appendingPathComponent(TitlePackage.fileName(for: p.name))
        try TitleTemplateLibrary.write(p, to: url)
        var back = try TitleTemplateLibrary.read(url) { _ in }
        back.app = nil; back.fonts = []
        guard back == p else { fail("\(p.name): .lctitle round trip changed the template") }
    }
    // A file that is not a template is refused.
    let junk = dir.appendingPathComponent("junk.lctitle")
    try Data("not a zip".utf8).write(to: junk)
    if (try? TitleTemplateLibrary.read(junk)) != nil { fail("junk .lctitle accepted") }
    print("title-check: .lctitle write/read OK")
} catch { fail(".lctitle: \(error)") }
print("title-check: PASS")
#else
print("title-check: macOS only")
#endif
