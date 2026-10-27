import Foundation
import XCTest
@testable import LiveCoreCore

final class InputAdjustTests: XCTestCase {
    func testIdentityLeavesColoursUnchanged() {
        let a = InputAdjust()
        XCTAssertTrue(a.isIdentity)
        let c = a.apply(r: 0.2, g: 0.5, b: 0.9)
        XCTAssertEqual(c.r, 0.2, accuracy: 1e-9); XCTAssertEqual(c.g, 0.5, accuracy: 1e-9); XCTAssertEqual(c.b, 0.9, accuracy: 1e-9)
        XCTAssertFalse(InputAdjust(flipHorizontal: true).isIdentity)
        XCTAssertFalse(InputAdjust(flipHorizontal: true).hasColorChange)
    }

    func testBrightnessContrastSaturationGamma() {
        XCTAssertEqual(InputAdjust(brightness: 0.1).apply(r: 0.5, g: 0.5, b: 0.5).r, 0.6, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust(contrast: 2).apply(r: 0.75, g: 0.75, b: 0.75).r, 1.0, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust(contrast: 2).apply(r: 0.4, g: 0.4, b: 0.4).r, 0.3, accuracy: 1e-9)
        let grey = InputAdjust(saturation: 0).apply(r: 1, g: 0, b: 0)
        XCTAssertEqual(grey.r, 0.2126, accuracy: 1e-9); XCTAssertEqual(grey.g, grey.r, accuracy: 1e-12)
        XCTAssertEqual(InputAdjust(gamma: 2).apply(r: 0.25, g: 0.25, b: 0.25).r, 0.5, accuracy: 1e-9)
        XCTAssertEqual(InputAdjust.pow(2, 10), 1024, accuracy: 1e-6)
    }

    func testClampingAndOldProjectsDecode() throws {
        let a = InputAdjust(brightness: 3, contrast: -1, saturation: 9, gamma: 0.1).clamped
        XCTAssertEqual(a, InputAdjust(brightness: 0.5, contrast: 0, saturation: 2, gamma: 0.5))
        let partial = try JSONDecoder().decode(InputAdjust.self, from: Data(#"{"brightness":0.2}"#.utf8))
        XCTAssertEqual(partial, InputAdjust(brightness: 0.2))
    }
}

final class ToneGeneratorTests: XCTestCase {
    func testLevelFrequencyAndContinuity() {
        var g = ToneGenerator(frequency: 1000, levelDB: -18)
        var a = [Float](repeating: 0, count: 480), b = a
        g.fill(&a, count: 480)
        g.fill(&b, count: 480)
        let peak = (a + b).map(abs).max()!
        XCTAssertEqual(Double(peak), 0.12589, accuracy: 0.001, "-18 dBFS peak")
        // 1 kHz at 48 kHz: one cycle every 48 samples, so sample 48 equals sample 0 and sample 12 is the crest.
        XCTAssertEqual(a[0], 0, accuracy: 1e-6)
        XCTAssertEqual(a[12], peak, accuracy: 1e-5)
        XCTAssertEqual(a[48], a[0], accuracy: 1e-5)
        XCTAssertEqual(b[0], a[0], accuracy: 1e-4, "phase continues across calls (480 = 10 cycles)")
        XCTAssertEqual(ToneGenerator.sine(0.25), 1, accuracy: 1e-9)
        XCTAssertEqual(ToneGenerator.sine(0.75), -1, accuracy: 1e-9)
    }

    func testProjectRoundTrip() throws {
        var doc = ProjectDocument()
        doc.audio.tones = [ProjectTone(id: "t1", frequency: 440, levelDB: -20)]
        var pi = ProjectInput(id: InputID("cam"), name: "Cam", source: .colorBars)
        pi.adjust = InputAdjust(brightness: 0.1, flipVertical: true)
        doc.inputs = [pi]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }
}
