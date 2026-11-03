import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.42.0: event rundown (the 9:16 output was removed in 0.55.0).
final class ShowTests: XCTestCase {
    func testCropFollower() {
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

    func testRundownSaved() throws {
        var doc = ProjectDocument()
        doc.rundown = Rundown.template("seminar")
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.rundown, doc.rundown)
    }
}
