import XCTest
import Foundation
@testable import LiveCoreCore

final class LayerStyleTests: XCTestCase {
    let canvas = PixelSize(width: 1920, height: 1080)

    func testNoCropMatchesPlainPlacement() throws {
        let d = try XCTUnwrap(LayerDraw.compute(rect: .full, source: PixelSize(width: 640, height: 480), mode: .fill,
                                                crop: .none, canvas: canvas))
        XCTAssertEqual(d.dest, PixelRect(x: 0, y: 0, width: 1920, height: 1080))
        // 4:3 filled into 16:9: the middle 75 % of the height is used.
        XCTAssertEqual(d.uv.0, 0, accuracy: 1e-9); XCTAssertEqual(d.uv.2, 1, accuracy: 1e-9)
        XCTAssertEqual(d.uv.1, 0.125, accuracy: 1e-9); XCTAssertEqual(d.uv.3, 0.875, accuracy: 1e-9)
        XCTAssertEqual(d.maskRect, d.dest)
    }

    func testCropSamplesOnlyTheKeptPart() throws {
        // Crop the left and right quarter of a 16:9 source, stretch into the full canvas.
        let crop = LayerStyle.Crop(left: 0.25, right: 0.25)
        let d = try XCTUnwrap(LayerDraw.compute(rect: .full, source: canvas, mode: .stretch, crop: crop, canvas: canvas))
        XCTAssertEqual(d.uv.0, 0.25, accuracy: 1e-9); XCTAssertEqual(d.uv.2, 0.75, accuracy: 1e-9)
        XCTAssertEqual(d.uv.1, 0, accuracy: 1e-9); XCTAssertEqual(d.uv.3, 1, accuracy: 1e-9)
        // Fit: the cropped picture is 8:9, so it is pillarboxed to 960 px wide.
        let f = try XCTUnwrap(LayerDraw.compute(rect: .full, source: canvas, mode: .fit, crop: crop, canvas: canvas))
        XCTAssertEqual(f.dest.width, 960, accuracy: 1); XCTAssertEqual(f.dest.x, 480, accuracy: 1)
    }

    func testMaskFollowsVisiblePictureAndCanvasClips() throws {
        // A layer hanging off the right edge: dest is clipped, the mask keeps the full box.
        let rect = NormRect(x: 0.8, y: 0.1, width: 0.4, height: 0.4)
        let d = try XCTUnwrap(LayerDraw.compute(rect: rect, source: PixelSize(width: 100, height: 100), mode: .stretch,
                                                crop: .none, canvas: canvas))
        XCTAssertEqual(d.maskRect.width, 768, accuracy: 1e-6)
        XCTAssertEqual(d.dest.width, 384, accuracy: 1e-6)
        XCTAssertEqual(d.uv.2, 0.5, accuracy: 1e-9)
        XCTAssertNil(LayerDraw.compute(rect: NormRect(x: 1.2, y: 0, width: 0.2, height: 0.2), source: canvas, mode: .fit,
                                       crop: .none, canvas: canvas))
    }

    func testClampingAndCodableCompatibility() throws {
        let s = LayerStyle(crop: .init(left: 0.8, top: -1, right: 0.4, bottom: .nan), cornerRadius: 2, borderWidth: 1).clamped
        XCTAssertEqual(s.crop.left, 0.45); XCTAssertEqual(s.crop.right, 0.4)
        let both = LayerStyle.Crop(left: 0.45, right: 0.45, bottom: 0.45).clamped
        XCTAssertEqual(both.left + both.right, 0.9, accuracy: 1e-9)
        XCTAssertEqual(s.crop.top, 0); XCTAssertEqual(s.crop.bottom, 0)
        XCTAssertEqual(s.cornerRadius, 0.5); XCTAssertEqual(s.borderWidth, 0.05)
        XCTAssertTrue(s.needsMask)
        XCTAssertFalse(LayerStyle().needsMask)
        XCTAssertTrue(LayerStyle(shape: .ellipse).needsMask)
        // Layers saved before 0.13.0 have no "style" key.
        let old = #"{"source":{"raw":"a"},"rect":{"x":0,"y":0,"width":1,"height":1},"scaleMode":"fit","opacity":1}"#
        let l = try JSONDecoder().decode(Layer.self, from: Data(old.utf8))
        XCTAssertNil(l.style)
        var styled = l; styled.style = LayerStyle(shape: .ellipse)
        XCTAssertEqual(try JSONDecoder().decode(Layer.self, from: JSONEncoder().encode(styled)), styled)
    }

    func testPlannerPassesStyleAndPreviewOverlays() {
        let a = InputID("a"), b = InputID("b"), logo = InputID("logo")
        let style = LayerStyle(cornerRadius: 0.2)
        let layers: [InputID: [Layer]] = [a: [Layer(source: a, style: style)], b: [Layer(source: b)], logo: [Layer(source: logo)]]
        var ov = OverlayChannel(index: 1, source: logo, preset: .pipTopRight)
        ov.onPreview = true
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: b, program: a), overlays: [ov], now: 0,
                                     layersFor: { layers[$0] })
        XCTAssertEqual(plan.program.first?.style, style)
        XCTAssertEqual(plan.preview.map(\.source), [b, logo])
        XCTAssertTrue(plan.overlays.isEmpty, "a preview overlay is not on Program")

        XCTAssertTrue(ov.takeToProgram(now: 10))
        XCTAssertFalse(ov.onPreview); XCTAssertTrue(ov.isOn)
        XCTAssertFalse(ov.takeToProgram(now: 11), "only once")
        let after = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: a, program: b), overlays: [ov], now: 20,
                                      layersFor: { layers[$0] })
        XCTAssertEqual(after.overlays.map(\.source), [logo])
        XCTAssertEqual(after.preview.map(\.source), [a])
    }
}

final class LottieProjectTests: XCTestCase {
    /// Lottie was removed in 0.15.0; projects that contain a Lottie input must still decode.
    func testLegacyLottieInputStillDecodes() throws {
        let pi = ProjectInput(id: InputID("l"), name: "Lower third", source: .lottie(path: "/a/b.json", relativePath: "b.json", loop: false))
        let back = try JSONDecoder().decode(ProjectInput.self, from: JSONEncoder().encode(pi))
        XCTAssertEqual(back.source, .lottie(path: "/a/b.json", relativePath: "b.json", loop: false))
    }
}

final class InputLockProjectTests: XCTestCase {
    func testLockedFlagRoundTripsAndIsOptional() throws {
        var pi = ProjectInput(id: InputID("cam"), name: "Cam", source: .color(ProjectColor(r: 0, g: 0, b: 0)))
        pi.locked = true
        let back = try JSONDecoder().decode(ProjectInput.self, from: JSONEncoder().encode(pi))
        XCTAssertEqual(back.locked, true)
        // Projects from before 0.14.0 have no "locked" key: the input is unlocked.
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(pi)) as? [String: Any])
        dict.removeValue(forKey: "locked")
        let old = try JSONDecoder().decode(ProjectInput.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertNil(old.locked)
    }
}
