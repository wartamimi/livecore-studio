import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.42.0: vertical 9:16 output crop and the event rundown.
final class ShowTests: XCTestCase {
    func testVerticalCropStaysInsideFrame() {
        let src = PixelSize(width: 1920, height: 1080)
        let c = VerticalCrop.rect(source: src, aspect: 9.0 / 16, centerX: 0.5)
        XCTAssertEqual(c.width, 607.5, accuracy: 0.01)
        XCTAssertEqual(c.height, 1080)
        XCTAssertEqual(c.x + c.width / 2, 960, accuracy: 0.01)
        XCTAssertEqual(VerticalCrop.rect(source: src, aspect: 9.0 / 16, centerX: 0).x, 0)
        let right = VerticalCrop.rect(source: src, aspect: 9.0 / 16, centerX: 1)
        XCTAssertEqual(right.x + right.width, 1920, accuracy: 0.01)
        // A portrait canvas narrower than 9:16 crops height instead.
        let tall = VerticalCrop.rect(source: PixelSize(width: 500, height: 1080), aspect: 9.0 / 16, centerX: 0.5)
        XCTAssertEqual(tall.width, 500); XCTAssertLessThan(tall.height, 1080)
    }

    func testFaceTargetAndFollower() {
        XCTAssertNil(VerticalCrop.target(faces: []))
        // The big face (speaker close to camera) dominates.
        let t = VerticalCrop.target(faces: [(0.2, 0.2), (0.8, 0.05)])!
        XCTAssertLessThan(t, 0.3)
        var f = CropFollower(x: 0.5, deadZone: 0.05)
        f.aim(at: 0.52)                 // inside the dead zone: no move
        XCTAssertEqual(f.target, 0.5)
        f.aim(at: 0.9)
        for _ in 0..<200 { _ = f.step(smoothing: 0.06) }
        XCTAssertEqual(f.x, 0.9, accuracy: 0.001)
        let mid = { () -> Double in var g = CropFollower(x: 0.1); g.aim(at: 0.9); return g.step(smoothing: 0.1) }()
        XCTAssertEqual(mid, 0.18, accuracy: 1e-9)   // eases, does not jump
    }

    func testRundownActions() {
        let cam1 = InputID("cam1"), cam2 = InputID("cam2"), t1 = InputID("t1"), t2 = InputID("t2")
        let akad = RundownSegment(title: "Akad", input: cam1, transition: .cut, titleInput: t1, overlayIndex: 2,
                                  music: .play, musicID: "m1")
        XCTAssertEqual(Rundown.actions(from: nil, to: akad),
                       [.program(cam1, auto: false), .overlayOn(2, t1), .musicPlay("m1")])
        let sambutan = RundownSegment(title: "Sambutan", input: cam2, titleInput: t2, overlayIndex: 2, music: .play, musicID: "m2")
        XCTAssertEqual(Rundown.actions(from: akad, to: sambutan),
                       [.overlayOff(2), .program(cam2, auto: true), .overlayOn(2, t2), .musicStop("m1"), .musicPlay("m2")])
        // Same title on the same channel stays on; music kept.
        let doa = RundownSegment(title: "Doa", titleInput: t2, overlayIndex: 2)
        XCTAssertEqual(Rundown.actions(from: sambutan, to: doa), [])
        let end = RundownSegment(title: "Penutup", music: .stop)
        XCTAssertEqual(Rundown.actions(from: sambutan, to: end), [.overlayOff(2), .musicStop("m2")])
        XCTAssertEqual(Rundown.remaining(RundownSegment(title: "x", minutes: 2), elapsed: 30), 90)
        XCTAssertNil(Rundown.remaining(RundownSegment(title: "x"), elapsed: 30))
        XCTAssertEqual(Rundown.template("wedding").segments[1].title, "Akad nikah")
    }

    func testRundownAndVerticalSaved() throws {
        var doc = ProjectDocument()
        doc.rundown = Rundown.template("seminar")
        doc.settings.vertical = VerticalSettings()
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.rundown, doc.rundown)
        XCTAssertEqual(back.settings.verticalOutput.size.height, 1280)
    }
}
