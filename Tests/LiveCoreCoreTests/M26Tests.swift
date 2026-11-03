import XCTest
@testable import LiveCoreCore

/// 0.26.0: Layer Designer drafts on Preview only, canvas orientations, video playlist shuffle.
final class M26Tests: XCTestCase {
    let a = InputID("a"), b = InputID("b")

    func testDraftShowsOnPreviewOnly() {
        let committed: [InputID: [Layer]] = [a: [Layer(source: a), Layer(source: b, rect: LayoutPreset.pipTopLeft.rect)], b: [Layer(source: b)]]
        let draft = [a: [Layer(source: a), Layer(source: b, rect: LayoutPreset.pipBottomRight.rect)]]
        // a is on Program and on Preview at the same time.
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: a, program: a), overlays: [], now: 0,
                                     layersFor: { committed[$0] }, fullPreview: true, previewLayers: draft)
        XCTAssertEqual(plan.program[1].rect, LayoutPreset.pipTopLeft.rect, "Program keeps the layers on air")
        XCTAssertEqual(plan.preview[1].rect, LayoutPreset.pipBottomRight.rect, "Preview shows the draft")
        XCTAssertEqual(plan.fullPreview?[1].rect, LayoutPreset.pipBottomRight.rect)
    }

    func testDraftOfFlattenedInputIsDrawnDirectly() {
        let committed: [InputID: [Layer]] = [a: [Layer(source: a, flatten: true), Layer(source: b)], b: [Layer(source: b)]]
        let draft = [a: [Layer(source: a, flatten: true), Layer(source: b, rect: LayoutPreset.pipTopRight.rect)]]
        let plan = FramePlanner.plan(snapshot: SwitcherSnapshot(preview: a), overlays: [], now: 0,
                                     layersFor: { committed[$0] }, previewLayers: draft)
        XCTAssertEqual(plan.preview.map(\.source), [a, b])
        XCTAssertEqual(plan.preview[1].rect, LayoutPreset.pipTopRight.rect)
    }

    func testCanvasPresets() {
        XCTAssertEqual(OutputFormat.canvas(.horizontal, lines: 1080, frameRate: 30).size, PixelSize(width: 1920, height: 1080))
        XCTAssertEqual(OutputFormat.canvas(.portrait, lines: 1080, frameRate: 30).size, PixelSize(width: 1080, height: 1920))
        XCTAssertEqual(OutputFormat.canvas(.portrait, lines: 720, frameRate: 60).size, PixelSize(width: 720, height: 1280))
        XCTAssertEqual(OutputFormat(size: PixelSize(width: 1080, height: 1920), frameRate: 30).orientation, .portrait)
        XCTAssertEqual(OutputFormat.hd720p30.orientation, .horizontal)
        XCTAssertEqual(OutputFormat(size: PixelSize(width: 1080, height: 1080), frameRate: 30).orientation, .custom)
        // Custom sizes are made even and kept within limits.
        XCTAssertEqual(OutputFormat.custom(width: 1081, height: 1349, frameRate: 30).size, PixelSize(width: 1080, height: 1348))
        XCTAssertEqual(OutputFormat.custom(width: 10, height: 99999, frameRate: 30).size, PixelSize(width: OutputFormat.minSide, height: OutputFormat.maxSide))
        var s = ProductionSettings()
        s.output = OutputFormat(size: PixelSize(width: 5000, height: 1000), frameRate: 30)
        XCTAssertFalse(s.validationErrors().isEmpty)
        s.output = .canvas(.portrait, lines: 1080, frameRate: 30)
        XCTAssertTrue(s.validationErrors().isEmpty)
    }

    func testPlaylistEndWithShuffle() {
        let n = PlaylistMath.next(index: 2, count: 5, loop: false, shuffle: true, random: { _ in 2 })
        XCTAssertEqual(n, 3, "shuffle never repeats the same clip")
        XCTAssertNil(PlaylistMath.next(index: 0, count: 1, loop: false, shuffle: true, random: { $0.lowerBound }))
    }

    func testSameCaptureTargetIsADuplicate() {
        let zoom = ProjectScreenCapture(target: .window, bundleID: "us.zoom.xos", windowTitle: "Zoom Meeting")
        XCTAssertTrue(zoom.sameTarget(as: ProjectScreenCapture(target: .window, bundleID: "us.zoom.xos", windowTitle: "Zoom Meeting", fps: 60)))
        XCTAssertFalse(zoom.sameTarget(as: ProjectScreenCapture(target: .window, bundleID: "us.zoom.xos", windowTitle: "Chat")))
        let d1 = ProjectScreenCapture(target: .display, displayID: 1)
        XCTAssertTrue(d1.sameTarget(as: ProjectScreenCapture(target: .display, displayID: 1, captureAudio: false)))
        XCTAssertFalse(d1.sameTarget(as: ProjectScreenCapture(target: .display, displayID: 2)))
        XCTAssertFalse(d1.sameTarget(as: zoom))
    }
}
