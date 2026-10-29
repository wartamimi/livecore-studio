import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.34.0: Title Designer templates, advanced settings and layout.
final class M34Tests: XCTestCase {
    let title = TitleSize(520, 64), sub = TitleSize(380, 40), tag = TitleSize(90, 40)

    func testCatalog() {
        XCTAssertEqual(TitleTemplate.allCases.count, 33)
        XCTAssertEqual(TitleTemplate.allCases.filter { $0.category == .lowerThird }.count, 19)
        XCTAssertEqual(TitleTemplate.allCases.filter { $0.category == .title }.count, 9)
        XCTAssertEqual(TitleTemplate.allCases.filter { $0.category == .corner }.count, 5)
        for t in TitleTemplate.allCases {
            let d = t.defaultDesign
            XCTAssertEqual(d.template, t)
            XCTAssertEqual(d, d.clamped(), "\(t) defaults are inside the editor ranges")
            XCTAssertFalse(t.sample.title.isEmpty)
            XCTAssertEqual(t.usesTag, !t.sample.tag.isEmpty, "\(t)")
        }
    }

    func testEveryTemplateStaysOnCanvas() {
        for (w, h) in [(1920.0, 1080.0), (1280.0, 720.0), (1080.0, 1920.0)] {
            for t in TitleTemplate.allCases {
                var d = t.defaultDesign
                d.tag = t.sample.tag
                let r = TitleLayout.layout(d, canvasWidth: w, canvasHeight: h, title: title, subtitle: sub, tag: t.usesTag ? tag : .zero)
                XCTAssertFalse(r.texts.isEmpty, "\(t)")
                XCTAssertTrue(r.texts.contains { $0.role == .title })
                for item in r.texts.map(\.rect) + r.boxes.map(\.rect) {
                    XCTAssertGreaterThanOrEqual(item.x, -0.5, "\(t) \(w)x\(h)")
                    XCTAssertGreaterThanOrEqual(item.y, -0.5, "\(t) \(w)x\(h)")
                    XCTAssertLessThanOrEqual(item.maxY, h + 0.5, "\(t) \(w)x\(h)")
                    if w >= 1280 { XCTAssertLessThanOrEqual(item.maxX, w + 0.5, "\(t) \(w)x\(h)") }
                }
            }
        }
    }

    func testStrapAnchorsAndAlign() {
        var d = TitleTemplate.classicStrap.defaultDesign
        let r = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        let box = r.boxes[0].rect
        XCTAssertEqual(box.x, 0.06 * 1920, accuracy: 0.01)
        XCTAssertEqual(box.maxY, 1080 - 0.08 * 1080, accuracy: 0.01, "bottom-left inside the safe margin")
        XCTAssertEqual(box.width, 520 + 2 * 28, accuracy: 0.01)
        let t = r.texts.first { $0.role == .title }!.rect
        let s = r.texts.first { $0.role == .subtitle }!.rect
        XCTAssertEqual(t.x, box.x + 28, accuracy: 0.01)
        XCTAssertEqual(s.y, t.maxY + 6, accuracy: 0.01)

        d.anchor = .topRight
        d.align = .right
        let r2 = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(r2.boxes[0].rect.maxX, 1920 - 0.06 * 1920, accuracy: 0.01)
        XCTAssertEqual(r2.boxes[0].rect.y, 0.08 * 1080, accuracy: 0.01)
        let s2 = r2.texts.first { $0.role == .subtitle }!.rect
        XCTAssertEqual(s2.maxX, r2.boxes[0].rect.maxX - 28, accuracy: 0.01, "right aligned")

        d.anchor = .center
        d.offsetX = 0.1
        let r3 = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        let b3 = r3.boxes[0].rect
        XCTAssertEqual(b3.x + b3.width / 2, 960 + 192, accuracy: 0.01)
        XCTAssertEqual(b3.y + b3.height / 2, 540, accuracy: 0.01)
    }

    func testScaleAndUnit() {
        var d = TitleTemplate.classicStrap.defaultDesign
        XCTAssertEqual(TitleLayout.unit(d, canvasWidth: 1280, canvasHeight: 720), 720.0 / 1080, accuracy: 1e-9)
        XCTAssertEqual(TitleLayout.unit(d, canvasWidth: 1080, canvasHeight: 1920), 1, accuracy: 1e-9, "portrait uses the width")
        d.scale = 2
        let r = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(r.boxes[0].rect.width, 520 + 4 * 28, accuracy: 0.01, "padding scales")
    }

    func testFullBarAndMinWidth() {
        let r = TitleLayout.layout(TitleTemplate.fullWidthBar.defaultDesign, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(r.boxes[0].rect.x, 0)
        XCTAssertEqual(r.boxes[0].rect.width, 1920)
        var d = TitleTemplate.roundedStrap.defaultDesign
        d.minWidth = 0.5
        let r2 = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(r2.boxes[0].rect.width, 960, accuracy: 0.01)
        XCTAssertEqual(r2.boxes[0].radius, 14)
    }

    func testPillRadius() {
        let r = TitleLayout.layout(TitleTemplate.pill.defaultDesign, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: .zero)
        XCTAssertEqual(r.boxes[0].radius, r.boxes[0].rect.height / 2, accuracy: 0.01)
        XCTAssertEqual(r.texts.count, 1, "no subtitle text")
    }

    func testTwoToneAndNews() {
        let tt = TitleLayout.layout(TitleTemplate.twoTone.defaultDesign, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(tt.boxes.map(\.fill), [.box, .box2])
        XCTAssertEqual(tt.boxes[1].rect.y, tt.boxes[0].rect.maxY, accuracy: 0.01, "subtitle box under the title box")
        XCTAssertEqual(tt.boxes[1].rect.x, tt.boxes[0].rect.x, accuracy: 0.01)

        var news = TitleTemplate.newsLive.defaultDesign
        let n = TitleLayout.layout(news, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub, tag: tag)
        XCTAssertEqual(n.boxes.map(\.fill), [.accent, .box, .box2])
        XCTAssertEqual(n.boxes[1].rect.x, n.boxes[0].rect.maxX, accuracy: 0.01, "title box right of the tag")
        let tagText = n.texts.first { $0.role == .tag }!.rect
        XCTAssertTrue(tagText.x >= n.boxes[0].rect.x && tagText.maxX <= n.boxes[0].rect.maxX)
        news.tag = ""
        let n2 = TitleLayout.layout(news, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub, tag: .zero)
        XCTAssertEqual(n2.boxes.map(\.fill), [.box, .box2])

        let banner = TitleLayout.layout(TitleTemplate.breakingBanner.defaultDesign, canvasWidth: 1920, canvasHeight: 1080,
                                        title: title, subtitle: sub, tag: tag)
        XCTAssertEqual(banner.boxes[0].rect.x, 0)
        XCTAssertEqual(banner.boxes.last!.rect.width, 1920, accuracy: 0.01)
    }

    func testCardAndUnderline() {
        let c = TitleLayout.layout(TitleTemplate.fullScreenTitle.defaultDesign, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(c.boxes.first?.rect, TitleRect(x: 0, y: 0, width: 1920, height: 1080))
        let t = c.texts.first { $0.role == .title }!.rect
        XCTAssertEqual(t.x + t.width / 2, 960, accuracy: 0.01, "centred")
        let u = TitleLayout.layout(TitleTemplate.minimalUnderline.defaultDesign, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        XCTAssertEqual(u.boxes.count, 1)
        XCTAssertEqual(u.boxes[0].fill, .accent)
        let ut = u.texts.first { $0.role == .title }!.rect
        let us = u.texts.first { $0.role == .subtitle }!.rect
        XCTAssertTrue(u.boxes[0].rect.y >= ut.maxY && u.boxes[0].rect.maxY <= us.y, "line between title and subtitle")
    }

    func testAccentLineSide() {
        var d = TitleTemplate.accentLine.defaultDesign
        let l = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        let bar = l.boxes.first { $0.fill == .accent }!.rect
        XCTAssertLessThan(bar.x, l.texts[0].rect.x)
        d.align = .right
        let r = TitleLayout.layout(d, canvasWidth: 1920, canvasHeight: 1080, title: title, subtitle: sub)
        let bar2 = r.boxes.first { $0.fill == .accent }!.rect
        XCTAssertGreaterThan(bar2.x, r.texts[0].rect.maxX)
    }

    func testClamp() {
        var d = TitleDesign(template: .pill)
        d.scale = 9
        d.titleSize = .nan
        d.offsetX = -3
        d.tag = String(repeating: "x", count: 99)
        let c = d.clamped()
        XCTAssertEqual(c.scale, 2)
        XCTAssertEqual(c.titleSize, 12)
        XCTAssertEqual(c.offsetX, -0.5)
        XCTAssertEqual(c.tag.count, 40)
    }

    func testCodableAndForwardCompatible() throws {
        var d = TitleTemplate.newsLive.defaultDesign
        d.fontFamily = "Helvetica Neue"
        d.outlineWidth = 2
        d.anchor = .top
        let back = try JSONDecoder().decode(TitleDesign.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        let partial = try JSONDecoder().decode(TitleDesign.self, from: Data(#"{"template":"pill","scale":5,"futureKey":1}"#.utf8))
        var expected = TitleTemplate.pill.defaultDesign
        expected.scale = 2
        XCTAssertEqual(partial, expected, "missing keys use the template defaults, values are clamped")
        let unknown = try JSONDecoder().decode(TitleDesign.self, from: Data(#"{"template":"spaceship"}"#.utf8))
        XCTAssertEqual(unknown.template, .classicStrap)
    }

    func testProjectTitleStyle() throws {
        var p = ProjectTitleStyle(title: "A", subtitle: "B")
        let oldJSON = String(decoding: try JSONEncoder().encode(p), as: UTF8.self)
        XCTAssertFalse(oldJSON.contains("design"), "classic titles are saved as before")
        p.design = TitleTemplate.quote.defaultDesign
        let back = try JSONDecoder().decode(ProjectTitleStyle.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }

    func testFromClassic() {
        let white = ProjectColor(r: 1, g: 1, b: 1)
        let bar = ProjectColor(r: 0.2, g: 0.3, b: 0.4, a: 0.8)
        let a = TitleDesign.fromClassic(layout: "barLeft", showBar: true, textColor: white, barColor: bar, titleSize: 60, subtitleSize: 30)
        XCTAssertEqual(a.template, .classicStrap)
        XCTAssertEqual(a.boxColor, bar)
        XCTAssertEqual(a.titleSize, 60)
        XCTAssertEqual(a.minWidth, 0.62)
        XCTAssertEqual(TitleDesign.fromClassic(layout: "fullWidth", showBar: false, textColor: white, barColor: bar, titleSize: nil, subtitleSize: nil).template, .fullWidthBar)
        let c = TitleDesign.fromClassic(layout: "centered", showBar: true, textColor: white, barColor: bar, titleSize: nil, subtitleSize: nil)
        XCTAssertEqual(c.template, .headline)
        XCTAssertFalse(c.showBox)
        XCTAssertEqual(c.anchor, .bottom)
    }
}
