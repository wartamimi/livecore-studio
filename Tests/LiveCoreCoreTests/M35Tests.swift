import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.35.0: running text in the Title Designer, title animations, ISO audio bus per input,
/// media auto restart and PowerPoint / PDF inputs.
final class M35Tests: XCTestCase {
    private func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    // MARK: Running text

    func testOldTickerConfigDecodesWithEarlierLook() throws {
        let json = #"{"text":"a","speed":120,"fontSize":44,"textColor":{"r":1,"g":1,"b":1,"a":1},"barColor":{"r":0.6,"g":0.05,"b":0.05,"a":0.9},"showBar":true,"bandHeight":0.08}"#
        let c = try JSONDecoder().decode(TickerConfig.self, from: Data(json.utf8))
        XCTAssertNil(c.template)
        XCTAssertEqual(c.labelText, "")
        XCTAssertEqual(c.separatorText, "•")
        XCTAssertEqual(c.textWeight, .semibold)
        XCTAssertNil(c.animation)
        XCTAssertEqual(c.layerRect.y, 1 - 0.08 - 0.04, accuracy: 1e-9)
    }

    func testTickerAdvancedFieldsRoundTripAndClamp() throws {
        var c = TickerTemplate.breakingYellow.config(text: "one\ntwo")
        c.label = String(repeating: "X", count: 40)
        c.separator = "<<<<>>>>>>"
        c.bandY = 2
        c.animationDuration = 99
        let k = c.clamped
        XCTAssertEqual(k.label?.count, 30)
        XCTAssertEqual(k.separator?.count, 8)
        XCTAssertEqual(k.bandY!, 1 - k.bandHeight, accuracy: 1e-9)
        XCTAssertEqual(k.animationDuration, 5)
        XCTAssertEqual(try roundTrip(c), c)
    }

    func testScrollTextUsesSeparatorAndUppercase() {
        var c = TickerConfig(text: "  first \n\nsecond\r\nthird  ")
        XCTAssertEqual(c.scrollText, "first   •   second   •   third")
        c.separator = "|"
        c.uppercase = true
        XCTAssertEqual(c.scrollText, "FIRST   |   SECOND   |   THIRD")
    }

    func testTickerTemplates() {
        for t in TickerTemplate.allCases {
            let c = t.config(text: "x")
            XCTAssertEqual(c.template, t)
            XCTAssertEqual(c, c.clamped, "\(t) is inside the editor ranges")
            XCTAssertNotNil(c.animation)
            let r = c.layerRect
            XCTAssertGreaterThanOrEqual(r.y, 0)
            XCTAssertLessThanOrEqual(r.y + r.height, 1 + 1e-9)
        }
        XCTAssertLessThan(TickerTemplate.topBand.config(text: "x").layerRect.y, 0.1)
        XCTAssertEqual(TickerTemplate.newsRed.config(text: "x").labelText, "NEWS")
        XCTAssertFalse(TickerTemplate.minimal.config(text: "x").showBar)
    }

    // MARK: Title animation

    func testTitleTemplatesHaveAnimation() throws {
        for t in TitleTemplate.allCases {
            let d = t.defaultDesign
            XCTAssertEqual(d.animation, t.defaultAnimation)
            XCTAssertFalse(d.useOverlayAnimation)
            XCTAssertEqual(d.animationDuration, t.category == .title ? 0.8 : 0.5, accuracy: 1e-9)
        }
        var d = TitleTemplate.allCases[0].defaultDesign
        d.animation = .zoom
        d.animationDuration = 1.2
        d.useOverlayAnimation = true
        XCTAssertEqual(try roundTrip(d), d)
        d.animationDuration = -3
        XCTAssertGreaterThan(d.clamped().animationDuration, 0)
    }

    // MARK: ISOCorder bus per input

    func testISOBusPerInput() throws {
        let a = InputID("a"), b = InputID("b")
        var m = MultiCorderConfig(inputs: [a, b])
        m.setBus(.busA, for: a)
        XCTAssertEqual(m.bus(for: a, profile: .master), .busA)
        XCTAssertEqual(m.bus(for: b, profile: .busB), .busB)
        XCTAssertEqual(m.ownBus(a), .busA)
        XCTAssertNil(m.ownBus(b))
        XCTAssertEqual(try roundTrip(m), m)

        let kept = m.keeping(existing: [b])
        XCTAssertNil(kept.ownBus(a))
        m.toggle(a)
        XCTAssertNil(m.ownBus(a), "removing an input forgets its bus")

        // No buses -> nothing written, so 0.34.0 projects stay byte-compatible.
        let plain = String(decoding: try JSONEncoder().encode(MultiCorderConfig(inputs: [a])), as: UTF8.self)
        XCTAssertFalse(plain.contains("buses"))
        XCTAssertNil(try roundTrip(MultiCorderConfig(inputs: [a])).ownBus(a))
    }

    // MARK: Full-screen overlay keeps the input's own layers

    func testFullScreenOverlayDrawsComposition() {
        let base = InputID("ticker"), cam = InputID("cam")
        let band = NormRect(x: 0, y: 0.88, width: 1, height: 0.08)
        let layers: [InputID: [Layer]] = [base: [Layer(source: base, rect: band)], cam: [Layer(source: cam)]]
        var ch = OverlayChannel(index: 1, source: base, preset: .fullScreen, fadeDuration: 0.5)
        ch.set(on: true, now: 0)
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: cam, program: cam), overlays: [ch], now: 10,
                                     layersFor: { layers[$0] })
        XCTAssertEqual(plan.overlays.count, 1)
        XCTAssertEqual(plan.overlays[0].rect, band, "drawn at the band position, not stretched full screen")

        var lt = OverlayChannel(index: 2, source: base, preset: .lowerThird, fadeDuration: 0.5)
        lt.set(on: true, now: 0)
        let p2 = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: cam, program: cam), overlays: [lt], now: 10,
                                   layersFor: { layers[$0] })
        XCTAssertEqual(p2.overlays.first?.rect, LayoutPreset.lowerThird.rect)
    }

    // MARK: Media auto restart

    func testAutoRestartIsOptionalInProjects() throws {
        var pi = ProjectInput(id: InputID("v"), name: "Clip", source: .videoFile(path: "/a.mp4", relativePath: nil, loop: true))
        XCTAssertNil(pi.autoRestart)
        pi.autoRestart = false
        XCTAssertEqual(try roundTrip(pi).autoRestart, false)
    }

    // MARK: Presentation

    func testPresentationProjectRoundTrip() throws {
        let p = ProjectPresentation(file: ProjectMediaRef(path: "/deck.pptx", relativePath: "deck.pptx"), slide: 4,
                                    background: ProjectColor(r: 1, g: 1, b: 1))
        let pi = ProjectInput(id: InputID("p"), name: "Deck", source: .presentation(p))
        let back = try roundTrip(pi)
        guard case let .presentation(q) = back.source else { return XCTFail("not a presentation") }
        XCTAssertEqual(q, p)
    }

    func testPresentationFileKinds() {
        XCTAssertFalse(PresentationFiles.needsConversion("PDF"))
        XCTAssertTrue(PresentationFiles.needsConversion("pptx"))
        XCTAssertEqual(PresentationFiles.converters(for: "key"), [.keynote])
        XCTAssertEqual(PresentationFiles.converters(for: "PPTX").first, .powerPoint)
        XCTAssertEqual(PresentationFiles.converter(for: "pptx", installed: [.libreOffice, .keynote]), .keynote)
        XCTAssertEqual(PresentationFiles.converter(for: "odp", installed: [.keynote]), .keynote)
        XCTAssertNil(PresentationFiles.converter(for: "pptx", installed: []))
        XCTAssertNil(PresentationFiles.converter(for: "key", installed: [.powerPoint]))
        XCTAssertTrue(PresentationFiles.all.isSuperset(of: ["pdf", "pptx", "ppt", "key", "odp"]))
    }

    func testSlideNavigation() {
        XCTAssertEqual(SlideMath.next(0, count: 3), 1)
        XCTAssertEqual(SlideMath.next(2, count: 3), 2, "stays on the last slide")
        XCTAssertEqual(SlideMath.next(2, count: 3, loop: true), 0)
        XCTAssertEqual(SlideMath.previous(0, count: 3), 0)
        XCTAssertEqual(SlideMath.clamp(9, count: 3), 2)
        XCTAssertEqual(SlideMath.clamp(4, count: 0), 0)
    }

    func testPageTransformHandlesRotation() {
        // A 400x300 crop box starting at (10, 20).
        for (rot, w, h) in [(0, 400.0, 300.0), (90, 300.0, 400.0), (180, 400.0, 300.0), (270, 300.0, 400.0), (-90, 300.0, 400.0)] {
            let (t, sw, sh) = SlideMath.pageTransform(minX: 10, minY: 20, maxX: 410, maxY: 320, rotation: rot)
            XCTAssertEqual(sw, w); XCTAssertEqual(sh, h)
            // All four corners land on the corners of the shown page.
            let corners = [(10.0, 20.0), (410.0, 20.0), (10.0, 320.0), (410.0, 320.0)].map { t.apply($0.0, $0.1) }
            for (x, y) in corners {
                XCTAssertTrue(abs(x) < 1e-9 || abs(x - sw) < 1e-9, "rot \(rot) x \(x)")
                XCTAssertTrue(abs(y) < 1e-9 || abs(y - sh) < 1e-9, "rot \(rot) y \(y)")
            }
        }
        // Rotated 90° clockwise: the page's top-left goes to the top-right.
        let (t90, w90, h90) = SlideMath.pageTransform(minX: 0, minY: 0, maxX: 400, maxY: 300, rotation: 90)
        let p = t90.apply(0, 300)
        XCTAssertEqual(p.0, w90, accuracy: 1e-9); XCTAssertEqual(p.1, h90, accuracy: 1e-9)
    }

    func testSlideFit() {
        let f = SlideMath.fit(720, 405, into: 1920, 1080)
        XCTAssertEqual(f.scale, 1920.0 / 720, accuracy: 1e-9)
        XCTAssertEqual(f.x, 0, accuracy: 1e-9); XCTAssertEqual(f.y, 0, accuracy: 1e-9)
        let g = SlideMath.fit(1024, 768, into: 1920, 1080)   // 4:3 slide -> pillarbox
        XCTAssertEqual(g.scale, 1080.0 / 768, accuracy: 1e-9)
        XCTAssertEqual(g.x, (1920 - 1024 * g.scale) / 2, accuracy: 1e-9)
        XCTAssertEqual(SlideMath.fit(0, 10, into: 100, 100).scale, 0)
    }
}
