import Foundation
import XCTest
@testable import LiveCoreCore

final class OnAirTests: XCTestCase {
    let cam = InputID("cam"), clip = InputID("clip"), logo = InputID("logo"), lt = InputID("lt"), other = InputID("other")

    func testProgramLayersAndOverlays() {
        let sw = Switcher()
        sw.setPreview(cam); sw.cut()
        var o = OverlayChannel(index: 1, source: lt)
        o.set(on: true, now: 0)
        let off = OverlayChannel(index: 2, source: other)
        let v = OnAir.visibleInputs(switcher: sw.state, layers: [cam: [Layer(source: logo)]], overlays: [o, off])
        XCTAssertEqual(v, [cam, logo, lt])
    }

    func testBothSidesOfATransitionAreOnAir() {
        let sw = Switcher()
        sw.setPreview(cam); sw.cut(); sw.setPreview(clip)
        sw.auto(kind: .dissolve, duration: 1, now: 0)
        XCTAssertEqual(OnAir.visibleInputs(switcher: sw.state, layers: [:], overlays: []), [cam, clip])
        sw.update(now: 2)
        XCTAssertEqual(OnAir.visibleInputs(switcher: sw.state, layers: [:], overlays: []), [clip])
    }

    func testAFVGate() {
        XCTAssertTrue(OnAir.audioOpen(link: nil, visible: []), "unlinked channels are never gated")
        XCTAssertTrue(OnAir.audioOpen(link: clip, visible: [clip]))
        XCTAssertFalse(OnAir.audioOpen(link: clip, visible: [cam]))
    }

    func testAFVLinkSurvivesProjectRoundTripAndOldProjectsDecode() throws {
        var ch = ProjectAudioChannel(deviceUniqueID: "mic", name: "Mic")
        ch.afvInput = cam
        let back = try JSONDecoder().decode(ProjectAudioChannel.self, from: JSONEncoder().encode(ch))
        XCTAssertEqual(back.afvInput, cam)
        let old = #"{"name":"Mic","faderDB":0,"gainDB":0,"pan":0,"muted":false,"toProgram":true,"compressorEnabled":false,"compThresholdDB":-18,"compRatio":3,"gateEnabled":false,"gateThresholdDB":-50}"#
        XCTAssertNil(try JSONDecoder().decode(ProjectAudioChannel.self, from: Data(old.utf8)).afvInput)
    }

    func testChannelStripSilencesWhenAFVClosed() {
        let controls = ChannelControls()
        var strip = ChannelStripDSP(controls: controls, sampleRate: 48_000)
        let n = 4800
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        controls.afvClosed.value = true
        for _ in 0..<5 {   // let the gain ramp settle
            l.update(repeating: 0.5, count: n); r.update(repeating: 0.5, count: n)
            strip.process(left: l, right: r, frames: n)
        }
        XCTAssertEqual(l[n - 1], 0, accuracy: 1e-6)
        controls.afvClosed.value = false
        for _ in 0..<5 {
            l.update(repeating: 0.5, count: n); r.update(repeating: 0.5, count: n)
            strip.process(left: l, right: r, frames: n)
        }
        XCTAssertGreaterThan(l[n - 1], 0.1)
    }
}
