import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.33.0: advanced recording profiles, MultiCorder profile, input colour groups and minimize.
final class M33Tests: XCTestCase {
    let a = InputID("a"), b = InputID("b"), c = InputID("c"), d = InputID("d"), e = InputID("e")

    func testRecordingDefaultsKeepOldBehaviour() {
        let r = RecordingSettings()
        XCTAssertEqual(r.videoCodec, .h264)
        XCTAssertEqual(r.keyframeInterval, 2)
        XCTAssertFalse(r.bFrames)
        XCTAssertEqual(r.audioKbps, 192)
        XCTAssertEqual(r.effectiveContainer, .mp4)
        XCTAssertFalse(r.usesPCM)
        XCTAssertTrue(r.validationErrors().isEmpty)
    }

    func testProResAndPCMForceMOV() {
        var r = RecordingSettings()
        r.codec = .proRes422HQ
        XCTAssertTrue(r.videoCodec.isProRes)
        XCTAssertFalse(r.videoCodec.usesBitrate)
        XCTAssertEqual(r.effectiveContainer, .mov)
        r.codec = .hevc
        XCTAssertEqual(r.effectiveContainer, .mp4)
        r.pcmAudio = true
        XCTAssertEqual(r.effectiveContainer, .mov)
        XCTAssertTrue(r.usesPCM)
    }

    func testValidation() {
        var r = RecordingSettings()
        r.bitrateKbps = 500
        XCTAssertEqual(r.validationErrors(label: "X").count, 1)
        r.codec = .proRes422
        XCTAssertTrue(r.validationErrors().isEmpty, "ProRes ignores the bitrate")
        r.keyframeSeconds = 20
        r.audioBitrateKbps = 100
        XCTAssertEqual(r.validationErrors().count, 2)
        var s = ProductionSettings()
        XCTAssertTrue(s.validationErrors().isEmpty)
        var m = RecordingSettings.multiCorderDefault
        m.bitrateKbps = 999_999
        s.multiCorder = m
        XCTAssertEqual(s.validationErrors(), ["ISOCorder: video bitrate must be 2–150 Mbps."])
    }

    func testEstimates() {
        var r = RecordingSettings()
        r.bitrateKbps = 20_000
        r.audioBitrateKbps = 320
        let hd = OutputFormat.hd1080p30
        XCTAssertEqual(r.estimatedMbps(output: hd), 20.32, accuracy: 0.001)
        XCTAssertEqual(r.gigabytesPerHour(output: hd, files: 4), 20.32 * 450 / 1000 * 4, accuracy: 0.001)
        r.codec = .proRes422
        r.pcmAudio = true
        let p30 = r.estimatedMbps(output: hd)
        XCTAssertEqual(p30, 147 * 30 / 29.97 + 2.304, accuracy: 0.01)
        let p60 = r.estimatedMbps(output: OutputFormat(size: hd.size, frameRate: 60))
        XCTAssertEqual(p60 - 2.304, (p30 - 2.304) * 2, accuracy: 0.01, "ProRes scales with the frame rate")
        XCTAssertEqual(r.gigabytesPerHour(output: hd, files: 0), 0)
    }

    func testMultiCorderProfile() throws {
        let m = RecordingSettings.multiCorderDefault
        XCTAssertEqual(m.videoCodec, .hevc)
        XCTAssertEqual(m.bitrateKbps, 25_000)
        XCTAssertEqual(m.effectiveContainer, .mov)
        var s = ProductionSettings()
        XCTAssertEqual(s.multiCorderRecording, m)
        s.recording.codec = .proRes422LT
        XCTAssertEqual(s.multiCorderRecording.videoCodec, .hevc, "the two profiles are independent")
        s.multiCorder = { var x = m; x.codec = .proRes422; return x }()
        let back = try JSONDecoder().decode(ProductionSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back, s)
    }

    func testOldSettingsDecode() throws {
        let old = #"{"folderPath":"","fileNamePattern":"X","container":"mov","bitrateKbps":8000,"minimumFreeBytes":1}"#
        let r = try JSONDecoder().decode(RecordingSettings.self, from: Data(old.utf8))
        XCTAssertNil(r.codec)
        XCTAssertEqual(r.videoCodec, .h264)
        XCTAssertEqual(r.effectiveContainer, .mov)
        let json = String(decoding: try JSONEncoder().encode(RecordingSettings()), as: UTF8.self)
        XCTAssertFalse(json.contains("codec"), "unchanged profiles are written as before")
    }

    func testGroupingWithoutTags() {
        let g = InputGrouping.groups(order: [a, b, c], tags: [:])
        XCTAssertEqual(g, [InputGroup(tag: nil, inputs: [a, b, c])])
        XCTAssertTrue(InputGrouping.usedTags(order: [a, b], tags: [:]).isEmpty)
    }

    func testGroupingOrderAndUntaggedLast() {
        let tags: [InputID: InputColorTag] = [b: .blue, c: .red, d: .blue]
        let g = InputGrouping.groups(order: [a, b, c, d, e], tags: tags)
        XCTAssertEqual(g, [InputGroup(tag: .blue, inputs: [b, d]),
                           InputGroup(tag: .red, inputs: [c]),
                           InputGroup(tag: nil, inputs: [a, e])])
        let used = InputGrouping.usedTags(order: [a, b, c, d, e], tags: tags)
        XCTAssertEqual(used.map { $0.tag }, [.blue, .red])
        XCTAssertEqual(used.map { $0.count }, [2, 1])
        let allTagged = InputGrouping.groups(order: [b, c], tags: tags)
        XCTAssertEqual(allTagged.map { $0.tag }, [.blue, .red], "no empty untagged group")
    }

    func testGroupingFilter() {
        let tags: [InputID: InputColorTag] = [b: .green, d: .green]
        XCTAssertEqual(InputGrouping.groups(order: [a, b, c, d], tags: tags, filter: .green),
                       [InputGroup(tag: .green, inputs: [b, d])])
        XCTAssertEqual(InputGrouping.groups(order: [a, b], tags: tags, filter: .pink),
                       [InputGroup(tag: .pink, inputs: [])])
    }

    func testProjectRoundTrip() throws {
        var i = ProjectInput(id: a, name: "A", source: .color(ProjectColor(r: 0, g: 0, b: 0, a: 1)))
        i.colorTag = .purple
        i.minimized = true
        var doc = ProjectDocument(inputs: [i])
        doc.groupNames = ["purple": "Kamera"]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc))
        XCTAssertEqual(back.inputs.first?.colorTag, .purple)
        XCTAssertEqual(back.inputs.first?.minimized, true)
        XCTAssertEqual(back.groupNames, ["purple": "Kamera"])
        XCTAssertEqual(back.sanitized().inputs.first?.colorTag, .purple)
        var plain = doc
        plain.inputs[0].colorTag = nil
        plain.inputs[0].minimized = nil
        plain.groupNames = nil
        let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("colorTag") || json.contains("minimized") || json.contains("groupNames"))
    }

    func testAllColoursHaveValidRGB() {
        XCTAssertEqual(InputColorTag.allCases.count, 8)
        for t in InputColorTag.allCases {
            for v in [t.rgb.r, t.rgb.g, t.rgb.b] { XCTAssertTrue((0...1).contains(v)) }
        }
    }
}
