import Foundation
import XCTest
@testable import LiveCoreCore

final class OutputDisplayTests: XCTestCase {
    let builtIn = DisplayInfo(id: 1, name: "Built-in Retina Display", isMain: true)
    let projector = DisplayInfo(id: 7, name: "EPSON PJ", isMain: false)
    let hdmi = DisplayInfo(id: 9, name: "HDMI TV", isMain: false)

    func testPrefersSavedDisplay() {
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: 9, savedName: nil, displays: [builtIn, projector, hdmi]), hdmi)
    }

    func testFallsBackToNameWhenIDChanged() {
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: 42, savedName: "HDMI TV", displays: [builtIn, projector, hdmi]), hdmi)
    }

    func testDefaultsToFirstExternalThenMain() {
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: [builtIn, projector]), projector)
        XCTAssertEqual(OutputDisplayPicker.choose(savedID: 9, savedName: "gone", displays: [builtIn]), builtIn)
        XCTAssertNil(OutputDisplayPicker.choose(savedID: nil, savedName: nil, displays: []))
    }

    func testLostDisplay() {
        XCTAssertTrue(OutputDisplayPicker.lost(projector, in: [builtIn]))
        XCTAssertFalse(OutputDisplayPicker.lost(projector, in: [builtIn, projector]))
    }

    func testFullscreenActionRoundTrips() throws {
        var map = MIDIMap()
        map.bind(MIDITrigger(kind: .note, channel: 0, number: 40), to: .fullscreenToggle)
        let back = try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(back.event(for: .noteOn(channel: 0, note: 40, velocity: 100)), .fire(.fullscreenToggle))
        XCTAssertTrue(ControlAction.catalog.contains(.fullscreenToggle))
    }
}

final class OutputBusTests: XCTestCase {
    func testAuxIndex() {
        XCTAssertNil(OutputBus.master.auxIndex)
        XCTAssertEqual(OutputBus.busA.auxIndex, 0)
        XCTAssertEqual(OutputBus.busB.auxIndex, 1)
    }

    func testOldSettingsDecodeAsMaster() throws {
        // Settings saved by 0.8.0 have no bus fields.
        var s = ProductionSettings()
        s.stream.additional = [StreamDestination(id: "fb", name: "Facebook", serverURL: "rtmp://x/live")]
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        var stream = json["stream"] as! [String: Any]
        stream["primaryAudioBus"] = nil
        json["stream"] = stream
        let back = try JSONDecoder().decode(ProductionSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.stream.primaryAudioBus, .master)
        XCTAssertEqual(back.stream.additional[0].bus, .master)
        XCTAssertEqual(back.recording.bus, .master)
    }

    func testBusSelectionRoundTrips() throws {
        var s = ProductionSettings()
        s.stream.primaryAudioBus = .busB
        s.stream.additional = [StreamDestination(id: "fb", name: "Facebook", serverURL: "rtmp://x/live")]
        s.stream.additional[0].audioBus = .busA
        s.recording.audioBus = .busA
        let back = try JSONDecoder().decode(ProductionSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.stream.primaryAudioBus, .busB)
        XCTAssertEqual(back.stream.additional[0].bus, .busA)
        XCTAssertEqual(back.recording.bus, .busA)
    }
}
