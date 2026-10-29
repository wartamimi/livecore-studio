import XCTest
@testable import LiveCoreCore

final class MIDITests: XCTestCase {
    func testParseStatusBytes() {
        XCTAssertEqual(MIDIMessage.parse(status: 0x90, data1: 60, data2: 100), .noteOn(channel: 0, note: 60, velocity: 100))
        XCTAssertEqual(MIDIMessage.parse(status: 0x93, data1: 60, data2: 0), .noteOff(channel: 3, note: 60))
        XCTAssertEqual(MIDIMessage.parse(status: 0x81, data1: 61, data2: 40), .noteOff(channel: 1, note: 61))
        XCTAssertEqual(MIDIMessage.parse(status: 0xB0, data1: 7, data2: 127), .controlChange(channel: 0, controller: 7, value: 127))
        XCTAssertNil(MIDIMessage.parse(status: 0xC0, data1: 1, data2: 0))
        XCTAssertNil(MIDIMessage.parse(status: 0xF8, data1: 0, data2: 0))
    }

    func testParseUMPWord() {
        // Type 2, group 0, note on ch 2, note 64, velocity 90
        XCTAssertEqual(MIDIMessage.parse(umpWord: 0x2092_405A), .noteOn(channel: 2, note: 64, velocity: 90))
        XCTAssertEqual(MIDIMessage.parse(umpWord: 0x20B0_0140), .controlChange(channel: 0, controller: 1, value: 64))
        XCTAssertNil(MIDIMessage.parse(umpWord: 0x1000_0000))   // system message type
    }

    func testParseByteStreamWithRunningStatusAndClock() {
        let msgs = MIDIMessage.parse(bytes: [0xB0, 1, 10, 0xF8, 1, 20, 0x90, 60, 100, 60, 0, 0xC0, 5])
        XCTAssertEqual(msgs, [.controlChange(channel: 0, controller: 1, value: 10),
                              .controlChange(channel: 0, controller: 1, value: 20),
                              .noteOn(channel: 0, note: 60, velocity: 100),
                              .noteOff(channel: 0, note: 60)])
    }

    func testMapButtonsAndFaders() {
        var map = MIDIMap()
        let pad = MIDITrigger(kind: .note, channel: 0, number: 36)
        let fader = MIDITrigger(kind: .cc, channel: 0, number: 7)
        let ccButton = MIDITrigger(kind: .cc, channel: 0, number: 20)
        map.bind(pad, to: .cut)
        map.bind(fader, to: .tbar)
        map.bind(ccButton, to: .preview(2))
        XCTAssertEqual(map.event(for: .noteOn(channel: 0, note: 36, velocity: 1)), .fire(.cut))
        XCTAssertNil(map.event(for: .noteOff(channel: 0, note: 36)))
        XCTAssertNil(map.event(for: .noteOn(channel: 1, note: 36, velocity: 100)))   // other channel
        XCTAssertEqual(map.event(for: .controlChange(channel: 0, controller: 7, value: 127)), .set(.tbar, value: 1))
        XCTAssertEqual(map.event(for: .controlChange(channel: 0, controller: 7, value: 0)), .set(.tbar, value: 0))
        XCTAssertEqual(map.event(for: .controlChange(channel: 0, controller: 20, value: 127)), .fire(.preview(2)))
        XCTAssertNil(map.event(for: .controlChange(channel: 0, controller: 20, value: 0)))
    }

    func testBindingReplacesOldTriggerAndAction() {
        var map = MIDIMap()
        let a = MIDITrigger(kind: .note, channel: 0, number: 36), b = MIDITrigger(kind: .note, channel: 0, number: 37)
        map.bind(a, to: .cut)
        map.bind(b, to: .cut)          // re-learn CUT on another pad
        XCTAssertEqual(map.trigger(for: .cut), b)
        XCTAssertNil(map.event(for: .noteOn(channel: 0, note: 36, velocity: 1)))
        map.bind(b, to: .auto)         // pad b now does AUTO, CUT is unbound
        XCTAssertNil(map.trigger(for: .cut))
        XCTAssertEqual(map.mappings.count, 1)
        map.clear(.auto)
        XCTAssertTrue(map.mappings.isEmpty)
    }

    func testMapCodableAndTriggerNames() throws {
        var map = MIDIMap()
        map.bind(MIDITrigger(kind: .note, channel: 9, number: 60), to: .overlay(2))
        map.bind(MIDITrigger(kind: .cc, channel: 0, number: 1), to: .tbar)
        let back = try JSONDecoder().decode(MIDIMap.self, from: JSONEncoder().encode(map))
        XCTAssertEqual(back, map)
        XCTAssertEqual(MIDITrigger(kind: .note, channel: 9, number: 60).description, "Note C4 · ch 10")
        XCTAssertEqual(MIDITrigger(kind: .cc, channel: 0, number: 1).description, "CC 1 · ch 1")
    }
}

final class PlaylistTests: XCTestCase {
    func testSequentialAndLoop() {
        XCTAssertEqual(PlaylistMath.next(index: 0, count: 3, loop: false, shuffle: false, random: { $0.lowerBound }), 1)
        XCTAssertNil(PlaylistMath.next(index: 2, count: 3, loop: false, shuffle: false, random: { $0.lowerBound }))
        XCTAssertEqual(PlaylistMath.next(index: 2, count: 3, loop: true, shuffle: false, random: { $0.lowerBound }), 0)
        XCTAssertNil(PlaylistMath.next(index: 0, count: 0, loop: true, shuffle: false, random: { $0.lowerBound }))
        XCTAssertEqual(PlaylistMath.previous(index: 0, count: 3), 2)
        XCTAssertEqual(PlaylistMath.previous(index: 2, count: 3), 1)
    }

    func testShuffleNeverRepeatsCurrentTrack() {
        for current in 0..<4 {
            for r in 0..<3 {
                let n = PlaylistMath.next(index: current, count: 4, loop: false, shuffle: true, random: { _ in r })
                XCTAssertNotNil(n)
                XCTAssertNotEqual(n, current)
                XCTAssertTrue((0..<4).contains(n!))
            }
        }
        // A single track with shuffle just repeats when looping.
        XCTAssertEqual(PlaylistMath.next(index: 0, count: 1, loop: true, shuffle: true, random: { _ in 0 }), 0)
    }

    func testMusicRoundTripsThroughProject() throws {
        var doc = ProjectDocument()
        var ch = ProjectAudioChannel(name: "Music")
        ch.faderDB = -12
        doc.audio.music = [ProjectMusic(id: "m1", name: "Background", tracks: [ProjectMediaRef(path: "/a.mp3", relativePath: "a.mp3")],
                                        shuffle: true, channel: ch)]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.audio.music, doc.audio.music)
    }
}

final class VideoPlaylistProjectTests: XCTestCase {
    func testPlaylistAndAutoPlayRoundTrip() throws {
        var doc = ProjectDocument()
        var pi = ProjectInput(id: InputID("v"), name: "Clips",
                              source: .videoPlaylist(tracks: [ProjectMediaRef(path: "/a.mov"), ProjectMediaRef(path: "/b.mp4", relativePath: "b.mp4")], loop: false))
        pi.autoPlay = "restartPause"
        doc.inputs = [pi]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back, doc)
    }

    func testOldInputsHaveNoAutoPlay() throws {
        let doc = ProjectDocument(inputs: [ProjectInput(id: InputID("v"), name: "Clip", source: .videoFile(path: "/a.mov", relativePath: nil, loop: true))])
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(doc)) as! [String: Any]
        var inputs = json["inputs"] as! [[String: Any]]
        inputs[0].removeValue(forKey: "autoPlay")
        json["inputs"] = inputs
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(back.inputs[0].autoPlay)
    }
}
