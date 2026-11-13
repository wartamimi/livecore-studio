import XCTest
@testable import LiveCoreCore

/// 0.60.0: audio plug-in inserts (Audio Unit / VST 3) — identifiers, scanner output, watchdog,
/// project storage and the channel-strip insert point.
final class V060Tests: XCTestCase {
    func testFourCCRoundTrip() {
        let id = FourCC.identifier(type: 0x6175_6678, subtype: 0x6C70_6173, manufacturer: 0x6170_706C)
        XCTAssertEqual(id, "aufx lpas appl")
        let p = FourCC.parse(identifier: id)
        XCTAssertEqual(p?.type, 0x6175_6678)
        XCTAssertEqual(p?.subtype, 0x6C70_6173)
        XCTAssertEqual(p?.manufacturer, 0x6170_706C)
        // Codes with spaces inside stay intact.
        XCTAssertNotNil(FourCC.parse(identifier: "aufx ap   abcd"))
        XCTAssertNil(FourCC.parse(identifier: "aufx lpas"))
    }

    func testScannerOutputIgnoresPluginChatter() {
        let out = """
        Plugin XYZ v1.2 licensed to someone
        [not json
        [{"cid":"4C43544741494E000000000000000001","name":"LiveCore Test Gain","vendor":"LiveCore Studio","version":"1.0.0","subCategories":"Fx|Tools"}]
        """
        let e = VST3ScanEntry.parse(scannerOutput: out)
        XCTAssertEqual(e?.count, 1)
        XCTAssertEqual(e?.first?.name, "LiveCore Test Gain")
        let d = e?.first?.descriptor(path: "/Library/Audio/Plug-Ins/VST3/LCTestGain.vst3")
        XCTAssertEqual(d?.format, .vst3)
        XCTAssertEqual(d?.identifier, "4C43544741494E000000000000000001")
        XCTAssertNil(VST3ScanEntry.parse(scannerOutput: "LCERR:not a bundle"))
    }

    func testSameClassIgnoresBundleLocation() {
        let a = AudioPluginDescriptor(format: .vst3, identifier: "AB", path: "/a/X.vst3", name: "X", vendor: "V")
        var b = a
        b.path = "/b/X.vst3"
        XCTAssertTrue(a.sameClass(as: b))
        XCTAssertNotEqual(a.id, b.id)
    }

    func testWatchdog() {
        var w = PluginWatchdog()
        for _ in 0..<(PluginWatchdog.maxConsecutiveErrors - 1) { XCTAssertEqual(w.record(ok: false, seconds: 0, blockSeconds: 0.01, finite: true), .none) }
        XCTAssertEqual(w.record(ok: true, seconds: 0, blockSeconds: 0.01, finite: true), .none)   // a good block resets
        for _ in 0..<(PluginWatchdog.maxConsecutiveErrors - 1) { _ = w.record(ok: false, seconds: 0, blockSeconds: 0.01, finite: true) }
        XCTAssertEqual(w.record(ok: false, seconds: 0, blockSeconds: 0.01, finite: true), .renderErrors)

        var s = PluginWatchdog()
        for _ in 0..<(PluginWatchdog.maxConsecutiveSlow - 1) { XCTAssertEqual(s.record(ok: true, seconds: 0.02, blockSeconds: 0.01, finite: true), .none) }
        XCTAssertEqual(s.record(ok: true, seconds: 0.02, blockSeconds: 0.01, finite: true), .tooSlow)

        var n = PluginWatchdog()
        XCTAssertEqual(n.record(ok: true, seconds: 0, blockSeconds: 0.01, finite: false), .none)
        XCTAssertEqual(n.record(ok: true, seconds: 0, blockSeconds: 0.01, finite: false), .none)
        XCTAssertEqual(n.record(ok: true, seconds: 0, blockSeconds: 0.01, finite: false), .invalidOutput)
    }

    func testProjectStoresPluginsAndOldProjectsDecode() throws {
        var ch = ProjectAudioChannel(deviceUniqueID: "mic", name: "Mic")
        let d = AudioPluginDescriptor(format: .audioUnit, identifier: "aufx lpas appl", name: "AULowpass", vendor: "Apple", isV3: false)
        ch.plugins = [ProjectPluginSlot(plugin: d, bypassed: true, state: Data([1, 2, 3]))]
        var audio = ProjectAudio()
        audio.channels = [ch]
        audio.masterPlugins = [ProjectPluginSlot(plugin: d)]
        let back = try JSONDecoder().decode(ProjectAudio.self, from: JSONEncoder().encode(audio))
        XCTAssertEqual(back, audio)
        XCTAssertEqual(back.channels[0].plugins?.first?.state, Data([1, 2, 3]))
        // 0.59 projects have no plug-in fields.
        let old = try JSONDecoder().decode(ProjectAudioChannel.self, from: Data(#"{"name":"Mic","faderDB":0,"gainDB":0,"pan":0,"muted":false,"toProgram":true,"compressorEnabled":false,"compThresholdDB":-18,"compRatio":3,"gateEnabled":false,"gateThresholdDB":-50}"#.utf8))
        XCTAssertNil(old.plugins)
    }

    /// The strip calls the inserts after the compressor and before the fader.
    func testChannelStripRunsInsertsBeforeFader() {
        final class Doubler: AudioInsertProcessing, @unchecked Sendable {
            var calls = 0
            var insertsActive: Bool { true }
            func processInserts(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) {
                calls += 1
                for i in 0..<frames { left[i] *= 2; right[i] *= 2 }
            }
        }
        let c = ChannelControls()
        c.faderDB.value = -6.0206   // × 0.5
        var dsp = ChannelStripDSP(controls: c, sampleRate: 48_000)
        let fx = Doubler()
        dsp.inserts = fx
        let n = 2048
        let l = UnsafeMutablePointer<Float>.allocate(capacity: n), r = UnsafeMutablePointer<Float>.allocate(capacity: n)
        defer { l.deallocate(); r.deallocate() }
        for _ in 0..<4 {   // let the fader ramp settle
            l.update(repeating: 0.25, count: n); r.update(repeating: 0.25, count: n)
            dsp.process(left: l, right: r, frames: n)
        }
        XCTAssertEqual(fx.calls, 4)
        XCTAssertEqual(l[n - 1], 0.25, accuracy: 0.001)   // 0.25 × 2 (insert) × 0.5 (fader)
    }
}
