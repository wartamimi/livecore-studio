import XCTest
@testable import LiveCoreCore

final class SwitcherTests: XCTestCase {
    let a = InputID("A"), b = InputID("B"), c = InputID("C")

    func testCutSwapsPreviewAndProgram() {
        let s = Switcher()
        s.setPreview(a); s.cut()
        XCTAssertEqual(s.state.program, a); XCTAssertNil(s.state.preview)
        s.setPreview(b); s.cut()
        XCTAssertEqual(s.state.program, b); XCTAssertEqual(s.state.preview, a)
    }

    func testAutoTransitionProgressesAndCompletes() {
        let s = Switcher()
        s.setPreview(a); s.cut(); s.setPreview(b)
        let ev = s.auto(kind: .dissolve, duration: 1.0, now: 10)
        XCTAssertEqual(ev, [.transitionStarted(.dissolve)])
        XCTAssertEqual(s.state.transition?.progress(at: 10.5) ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(s.state.program, a, "program does not change until the transition completes")
        XCTAssertTrue(s.update(now: 10.9).isEmpty)
        XCTAssertEqual(s.setPreview(c), [], "preview locked during transition")
        let done = s.update(now: 11.0)
        XCTAssertTrue(done.contains(.transitionCompleted))
        XCTAssertEqual(s.state.program, b); XCTAssertEqual(s.state.preview, a); XCTAssertNil(s.state.transition)
    }

    func testCutDuringTransitionCompletesIt() {
        let s = Switcher()
        s.setPreview(a); s.cut(); s.setPreview(b)
        s.auto(kind: .wipeLeft, duration: 2, now: 0)
        s.cut()
        XCTAssertEqual(s.state.program, b); XCTAssertNil(s.state.transition)
    }

    func testAutoWithCutKindIsInstant() {
        let s = Switcher()
        s.setPreview(a)
        s.auto(kind: .cut, duration: 1, now: 0)
        XCTAssertEqual(s.state.program, a); XCTAssertNil(s.state.transition)
    }

    func testTBarManualTransition() {
        let s = Switcher()
        s.setPreview(a); s.cut(); s.setPreview(b)
        s.setTBar(0.3, kind: .dissolve, now: 0)
        XCTAssertEqual(s.state.transition?.progress(at: 99) ?? -1, 0.3, accuracy: 1e-9, "manual position ignores time")
        XCTAssertTrue(s.update(now: 100).isEmpty)
        s.setTBar(1.0, kind: .dissolve, now: 0)
        XCTAssertEqual(s.state.program, b)
        // Abort back to 0
        s.setPreview(c)
        s.setTBar(0.5, kind: .dissolve, now: 0); s.setTBar(0, kind: .dissolve, now: 0)
        XCTAssertEqual(s.state.program, b); XCTAssertEqual(s.state.preview, c); XCTAssertNil(s.state.transition)
    }

    func testRemovingOnAirInputGoesToBlackWithoutCrash() {
        let s = Switcher()
        s.setPreview(a); s.cut(); s.setPreview(b)
        s.auto(kind: .dissolve, duration: 1, now: 0)
        let ev = s.inputRemoved(a)
        XCTAssertTrue(ev.contains(.programChanged(nil)))
        XCTAssertNil(s.state.transition); XCTAssertNil(s.state.program); XCTAssertEqual(s.state.preview, b)
        s.cut()
        XCTAssertEqual(s.state.program, b)
    }

    func testOverlayFadeInOut() {
        var o = OverlayChannel(index: 1, source: a, preset: .lowerThird, fadeDuration: 0.5)
        XCTAssertFalse(o.isVisible(at: 0))
        o.set(on: true, now: 0)
        XCTAssertEqual(o.opacity(at: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(o.opacity(at: 1), 1)
        o.set(on: false, now: 1.0)
        XCTAssertEqual(o.opacity(at: 1.25), 0.5, accuracy: 1e-9)
        XCTAssertFalse(o.isVisible(at: 2))
        // Reverse mid-fade starts from current opacity, no jump.
        o.set(on: true, now: 2); o.set(on: false, now: 2.25)
        XCTAssertEqual(o.opacity(at: 2.25), 0.5, accuracy: 1e-9)
    }

    func testFramePlanDuringTransitionAndOverlays() {
        let s = Switcher()
        s.setPreview(a); s.cut(); s.setPreview(b)
        s.auto(kind: .fadeToBlack, duration: 2, now: 0)
        var ov = OverlayChannel(index: 1, source: c, preset: .pipTopRight, fadeDuration: 0)
        ov.set(on: true, now: 0)
        let scenes: [InputID: [Layer]] = [
            a: [Layer(source: a)],
            b: [Layer(source: b), Layer(source: c, rect: LayoutPreset.pipBottomLeft.rect), Layer(source: InputID("gone"))],
            c: [Layer(source: c)],
        ]
        let plan = FramePlanner.plan(snapshot: s.state, overlays: [ov], now: 0.5, layersFor: { scenes[$0] })
        XCTAssertEqual(plan.program.map(\.source), [a])
        XCTAssertEqual(plan.transition?.kind, .fadeToBlack)
        XCTAssertEqual(plan.transition?.progress ?? -1, 0.25, accuracy: 1e-9)
        XCTAssertEqual(plan.transition?.incoming.map(\.source), [b, c], "dangling layer dropped")
        XCTAssertEqual(plan.overlays.first?.rect, LayoutPreset.pipTopRight.rect)
        XCTAssertEqual(plan.preview.map(\.source), [b, c])
        let empty = FramePlanner.plan(snapshot: SwitcherSnapshot(), overlays: [], now: 0, layersFor: { scenes[$0] })
        XCTAssertTrue(empty.program.isEmpty, "no program = black")
    }

    func testLayoutMath() {
        let box = PixelRect(x: 0, y: 0, width: 1920, height: 1080)
        let fit43 = LayoutMath.place(source: PixelSize(width: 640, height: 480), in: box, mode: .fit)
        XCTAssertEqual(fit43, PixelRect(x: 240, y: 0, width: 1440, height: 1080))
        let fill43 = LayoutMath.place(source: PixelSize(width: 640, height: 480), in: box, mode: .fill)
        XCTAssertEqual(fill43.width, 1920); XCTAssertEqual(fill43.height, 1440); XCTAssertEqual(fill43.y, -180)
        XCTAssertEqual(LayoutMath.place(source: PixelSize(width: 10, height: 10), in: box, mode: .stretch), box)
        XCTAssertEqual(LayoutMath.evenSize(PixelSize(width: 1281, height: 721)), PixelSize(width: 1280, height: 720))
        XCTAssertNil(LayoutMath.intersect(PixelRect(x: 0, y: 0, width: 1, height: 1), PixelRect(x: 2, y: 2, width: 1, height: 1)))
        XCTAssertEqual(LayoutMath.toPixels(LayoutPreset.lowerThird.rect, canvas: PixelSize(width: 1000, height: 1000)).y, 700, accuracy: 1e-9)
    }
}
