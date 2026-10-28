import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.36.0: web input options, letter-by-letter title animation, PowerPoint live mode and camera frames.
final class M36Tests: XCTestCase {
    private func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    // MARK: Web input

    func testBrowserOptionsAreOptional() throws {
        let old = try JSONDecoder().decode(ProjectBrowser.self, from: Data(
            #"{"url":"https://a.com","width":1920,"height":1080,"fps":15,"transparent":true}"#.utf8))
        XCTAssertNil(old.videoOnly)
        XCTAssertEqual(old.pageZoom, 1)
        XCTAssertNil(old.userScript, "no options = no script injected")

        var b = old
        b.videoOnly = true
        b.zoom = 9
        b.css = "body { color: red }"
        b.muted = true
        XCTAssertEqual(b.pageZoom, ProjectBrowser.zoomRange.upperBound)
        XCTAssertEqual(try roundTrip(b), b)
        let js = try XCTUnwrap(b.userScript)
        XCTAssertTrue(js.contains("livecore-css"))
        XCTAssertTrue(js.contains("m.muted = true"))
        XCTAssertTrue(js.contains("object-fit: contain"))
        b.zoom = .nan
        XCTAssertEqual(b.pageZoom, 1)
    }

    func testJSStringEscapesEverything() {
        XCTAssertEqual(ProjectBrowser.jsString(#"a"b\c"#), #""a\"b\\c""#)
        XCTAssertEqual(ProjectBrowser.jsString("x\ny"), #""x\ny""#)
        // A CSS value cannot end the script or the string.
        let s = ProjectBrowser.jsString("</script><script>alert(1)</script>\"; evil()")
        XCTAssertFalse(s.contains("</script>"))
        let inner = Array(s.dropFirst().dropLast())
        for (i, ch) in inner.enumerated() where ch == "\"" { XCTAssertEqual(inner[i - 1], "\\", "quote escaped") }
        XCTAssertTrue(s.hasPrefix("\"") && s.hasSuffix("\""))
    }

    // MARK: Letter animation

    func testTextRevealTiming() {
        let r = TextReveal(animation: .fade, delay: 0.05)
        XCTAssertEqual(r.progress(letter: 0, at: 0), 0)
        XCTAssertEqual(r.progress(letter: 0, at: 0.35), 1, accuracy: 1e-9)
        XCTAssertEqual(r.progress(letter: 2, at: 0.1), 0, "letter 2 starts at 0.1 s")
        XCTAssertEqual(r.progress(letter: 2, at: 0.1 + 0.175), 0.5, accuracy: 1e-9)
        XCTAssertEqual(r.totalDuration(letters: 10), 9 * 0.05 + 0.35, accuracy: 1e-9)
        XCTAssertEqual(r.totalDuration(letters: 0), 0)

        let tw = TextReveal(animation: .typewriter, delay: 0.1)
        XCTAssertEqual(tw.progress(letter: 3, at: 0.29), 0)
        XCTAssertEqual(tw.progress(letter: 3, at: 0.31), 1)
        XCTAssertEqual(tw.opacity(0.4), 1)

        let off = TextReveal(animation: .off, delay: 0.1)
        XCTAssertEqual(off.progress(letter: 50, at: 0), 1)
        XCTAssertEqual(off.totalDuration(letters: 50), 0)

        XCTAssertEqual(TextReveal(animation: .fade, delay: 9).delay, 0.3, "delay clamped")
        XCTAssertEqual(TextReveal(animation: .fade, delay: .nan).delay, 0.04)
    }

    func testLetterMotion() {
        let rise = TextReveal(animation: .rise, delay: 0.04)
        XCTAssertLessThan(rise.offset(0), 0, "rise starts below")
        XCTAssertEqual(rise.offset(1), 0, accuracy: 1e-12)
        XCTAssertGreaterThan(TextReveal(animation: .drop, delay: 0.04).offset(0), 0, "drop starts above")
        let pop = TextReveal(animation: .pop, delay: 0.04)
        XCTAssertLessThan(pop.scale(0), 1)
        XCTAssertEqual(pop.scale(1), 1, accuracy: 1e-12)
        XCTAssertEqual(rise.scale(0), 1)
        for p in stride(from: 0.0, through: 1.0, by: 0.1) {
            XCTAssertGreaterThanOrEqual(TextReveal.ease(p), p - 1e-12, "ease-out is ahead of linear")
        }
    }

    func testTitleDesignLetterAnimationDecodes() throws {
        var d = TitleTemplate.headline.defaultDesign
        XCTAssertEqual(d.textAnimation, .off)
        d.textAnimation = .rise
        d.letterDelay = 2
        XCTAssertEqual(d.clamped().letterDelay, 0.3)
        let back = try roundTrip(d)
        XCTAssertEqual(back.textAnimation, .rise)
        XCTAssertEqual(back.letterDelay, 0.3, "decoded designs are clamped")
    }

    // MARK: PowerPoint live

    func testPresentationLiveFlag() throws {
        let p = ProjectPresentation(file: ProjectMediaRef(path: "/d.pptx"), slide: 2, live: true)
        XCTAssertEqual(try roundTrip(p).live, true)
        let old = try JSONDecoder().decode(ProjectPresentation.self, from: Data(#"{"file":{"path":"/d.pdf"},"slide":0}"#.utf8))
        XCTAssertNil(old.live)
    }

    // MARK: Frames

    func testFrameTemplatesKeepTheWindowOnCanvas() {
        for aspect in [16.0 / 9, 4.0 / 3, 9.0 / 16] {
            for t in FrameTemplate.allCases {
                let l = FrameLayout.layout(t, aspect: aspect)
                let c = l.camera
                XCTAssertGreaterThanOrEqual(c.x, -1e-9, "\(t) \(aspect)")
                XCTAssertGreaterThanOrEqual(c.y, -1e-9, "\(t) \(aspect)")
                XCTAssertLessThanOrEqual(c.x + c.width, 1 + 1e-9, "\(t) \(aspect)")
                XCTAssertLessThanOrEqual(c.y + c.height, 1 + 1e-9, "\(t) \(aspect)")
                XCTAssertGreaterThan(c.width, 0.05)
                XCTAssertGreaterThan(c.height, 0.05)
                XCTAssertEqual(l.cameraStyle(accent: ProjectColor(r: 1, g: 0, b: 0)), l.cameraStyle(accent: ProjectColor(r: 1, g: 0, b: 0)).clamped)
                if let label = l.label {
                    XCTAssertLessThanOrEqual(label.y + label.height, 1 + 1e-9, "\(t) label")
                }
            }
        }
    }

    func testCircleFrameIsRoundOnScreen() {
        let a = 16.0 / 9
        let l = FrameLayout.layout(.circle, aspect: a)
        XCTAssertEqual(l.shape, .ellipse)
        XCTAssertEqual(l.camera.width * a, l.camera.height, accuracy: 1e-9, "same width and height in pixels")
        let v = FrameLayout.layout(.vertical, aspect: a)
        XCTAssertEqual(v.camera.width * a / v.camera.height, 9.0 / 16, accuracy: 1e-9)
    }

    func testPolaroidWindowInsideCard() throws {
        let l = FrameLayout.layout(.polaroid, aspect: 16.0 / 9)
        let card = try XCTUnwrap(l.card)
        XCTAssertGreaterThan(l.camera.x, card.x)
        XCTAssertGreaterThan(l.camera.y, card.y)
        XCTAssertLessThan(l.camera.x + l.camera.width, card.x + card.width)
        XCTAssertLessThan(l.camera.y + l.camera.height, card.y + card.height)
    }

    func testFrameDesignRoundTripAndDefaults() throws {
        for t in FrameTemplate.allCases {
            var d = t.defaultDesign
            XCTAssertEqual(d.template, t)
            d.title = "Ana"
            d.transparentBackground = true
            XCTAssertEqual(try roundTrip(d), d)
        }
        XCTAssertTrue(FrameTemplate.broadcast.usesTag)
        XCTAssertEqual(FrameTemplate.broadcast.defaultDesign.tag, "LIVE")
        // Missing keys use the template's defaults.
        let partial = try JSONDecoder().decode(FrameDesign.self, from: Data(#"{"template":"neon","title":"X"}"#.utf8))
        XCTAssertEqual(partial.title, "X")
        XCTAssertEqual(partial.accent, FrameTemplate.neon.defaultDesign.accent)
        let pi = ProjectInput(id: InputID("f"), name: "Frame", source: .frame(partial))
        guard case let .frame(back) = try roundTrip(pi).source else { return XCTFail("not a frame") }
        XCTAssertEqual(back, partial)
    }
}
