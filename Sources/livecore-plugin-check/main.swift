// CI check (0.60.0): hosts real plug-ins through the same code the mixer uses.
//   * Audio Unit: Apple's AULowpass (ships with macOS) — scanned, loaded (out of process when the
//     runner allows it), processed (15 kHz attenuated, 100 Hz passes), state saved and restored.
//   * VST 3: the LiveCore test gain plug-in (LCTestGainVST3, built by SwiftPM) wrapped into a
//     .vst3 bundle — scanned in a child process, loaded, processed, parameter changed through
//     the controller, state saved and restored into a new instance.
// Usage: livecore-plugin-check <path to libLCTestGainVST3.dylib>
#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine

PluginScanChild.runIfRequested()

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "PASS " : "FAIL ") + what)
    if !ok { failures += 1 }
}

func spin(timeout: TimeInterval, until done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    return done()
}

let frames = 512
let left = UnsafeMutablePointer<Float>.allocate(capacity: frames)
let right = UnsafeMutablePointer<Float>.allocate(capacity: frames)
var phase = 0.0
func fillSine(_ hz: Double, _ amp: Float) {
    for i in 0..<frames {
        let v = amp * Float(sin(2 * Double.pi * hz * (phase + Double(i)) / 48_000))
        left[i] = v; right[i] = v
    }
    phase += Double(frames)
}
func fillDC(_ v: Float) { for i in 0..<frames { left[i] = v; right[i] = v } }
func rms() -> Float {
    var s: Float = 0
    for i in 0..<frames { s += left[i] * left[i] }
    return (s / Float(frames)).squareRoot()
}
/// Runs `blocks` blocks through the chain and returns the RMS of the last one.
func run(_ chain: PluginInsertChain, blocks: Int, fill: () -> Void) -> Float {
    var r: Float = 0
    for _ in 0..<blocks { fill(); chain.processInserts(left: left, right: right, frames: frames); r = rms() }
    return r
}

// Build the VST 3 bundle around the test plug-in library.
var extra: [URL] = []
let args = CommandLine.arguments
if args.count > 1 {
    let dylib = URL(fileURLWithPath: args[1])
    let bundle = FileManager.default.temporaryDirectory.appendingPathComponent("lc-plugin-check/LCTestGain.vst3")
    let macos = bundle.appendingPathComponent("Contents/MacOS")
    try? FileManager.default.removeItem(at: bundle)
    try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: dylib, to: macos.appendingPathComponent("LCTestGain"))
    let plist: [String: Any] = ["CFBundleExecutable": "LCTestGain", "CFBundleIdentifier": "studio.livecore.testgain",
                                "CFBundlePackageType": "BNDL", "CFBundleName": "LCTestGain", "CFBundleVersion": "1.0"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    extra = [bundle]
    check(FileManager.default.fileExists(atPath: dylib.path), "test plug-in library exists (\(dylib.path))")
} else {
    print("NOTE no test plug-in library given: VST 3 part skipped")
}

let host = AudioPluginHost()
host.onNotice = { print("notice: \($0)") }
var scanned = false
host.catalog.scan(force: true, extraVST3: extra) { scanned = true }
check(spin(timeout: 120) { scanned }, "plug-in scan finished")
print("found \(host.catalog.audioUnits.count) Audio Units, \(host.catalog.vst3.count) VST 3; failures: \(host.catalog.failures)")

// MARK: Audio Unit
if let lp = host.catalog.audioUnits.first(where: { $0.identifier == "aufx lpas appl" }) {
    for outOfProcess in [true, false] {
        host.auOutOfProcess = outOfProcess
        let chain = PluginInsertChain()
        var added: PluginSlot?
        host.add(lp, to: chain) { added = $0 }
        _ = spin(timeout: 30) { added != nil }
        guard let slot = added else { check(false, "AULowpass loads (out of process: \(outOfProcess))"); continue }
        if let e = slot.loadError {
            // Out-of-process hosting needs a GUI session on some runners: report, do not fail.
            print((outOfProcess ? "NOTE " : "FAIL ") + "AULowpass load error (out of process: \(outOfProcess)): \(e)")
            if !outOfProcess { failures += 1 }
            continue
        }
        print("AULowpass loaded, isolated: \(slot.outOfProcess)")
        let high = run(chain, blocks: 40) { fillSine(15_000, 0.5) }
        let low = run(chain, blocks: 40) { fillSine(100, 0.5) }
        check(high < 0.1, "AULowpass attenuates 15 kHz (rms \(high))")
        check(low > 0.25, "AULowpass passes 100 Hz (rms \(low))")
        let saved = chain.projectSlots()
        check(saved?.first?.state != nil, "AULowpass state saved (\(saved?.first?.state?.count ?? 0) bytes)")
        let chain2 = PluginInsertChain()
        var restored = false
        host.restore(saved, into: chain2) { restored = true }
        _ = spin(timeout: 30) { restored }
        check(chain2.slots.count == 1 && chain2.slots[0].isLoaded, "AULowpass restored from project state")
        chain.slots.first?.bypassed.value = true
        let bypassed = run(chain, blocks: 4) { fillSine(15_000, 0.5) }
        check(bypassed > 0.3, "bypass passes audio unchanged (rms \(bypassed))")
        chain.removeAll(); chain2.removeAll()
        if outOfProcess && slot.outOfProcess { break }   // in process is only the fallback
    }
} else {
    check(false, "Apple AULowpass found by the scan")
}

// MARK: VST 3
if !extra.isEmpty {
    if let gain = host.catalog.vst3.first(where: { $0.name == "LiveCore Test Gain" }) {
        check(gain.identifier == "4C43544741494E000000000000000001", "VST 3 class id read by the child scanner")
        let chain = PluginInsertChain()
        var added: PluginSlot?
        host.add(gain, to: chain) { added = $0 }
        _ = spin(timeout: 10) { added != nil }
        if let slot = added, slot.isLoaded {
            check(abs(run(chain, blocks: 2) { fillDC(0.5) } - 0.5) < 0.001, "VST 3 processes at unity gain")
            let params = slot.parameters()
            check(params.count == 1 && params[0].name == "Gain", "VST 3 parameter listed (\(params.map(\.name)))")
            slot.setParameter(0, normalized: 1.0)
            check(abs(run(chain, blocks: 2) { fillDC(0.5) } - 1.0) < 0.001, "VST 3 parameter change reaches the processor")
            check(slot.display(0, normalized: 1.0) == "2.00", "VST 3 parameter display text")
            let saved = chain.projectSlots()
            let chain2 = PluginInsertChain()
            var restored = false
            host.restore(saved, into: chain2) { restored = true }
            _ = spin(timeout: 10) { restored }
            check(abs(run(chain2, blocks: 2) { fillDC(0.5) } - 1.0) < 0.001, "VST 3 state restored into a new instance")
            chain.removeAll(); chain2.removeAll()
        } else {
            check(false, "VST 3 test plug-in loads (\(added?.loadError ?? "timeout"))")
        }
    } else {
        check(false, "VST 3 test plug-in found by the child-process scan")
    }
}

host.shutdown()
print(failures == 0 ? "plugin-check: all passed" : "plugin-check: \(failures) failed")
exit(failures == 0 ? 0 : 1)
#else
print("livecore-plugin-check runs on macOS only")
#endif
