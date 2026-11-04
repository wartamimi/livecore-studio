#if os(macOS)
import AppKit
import AudioToolbox
import AVFoundation
import CVST3
import LiveCoreCore

/// A parameter for the generic editor (plug-ins without a window of their own).
public struct PluginParameter: Identifiable, Sendable {
    public let id: UInt64
    public let name: String
    public let unit: String
    /// Normalised 0…1.
    public var value: Double
    /// Discrete steps (0 = continuous).
    public let steps: Int
}

/// One loaded plug-in instance. `process` runs on the render thread; everything else on main.
protocol PluginProcessor: AnyObject {
    var channels: Int { get }
    var latencySamples: Int { get }
    /// Runs out of process (a crash there cannot take LiveCore down).
    var outOfProcess: Bool { get }
    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool
    func state() -> Data?
    func restore(_ data: Data) -> Bool
    func parameters() -> [PluginParameter]
    func setParameter(_ id: UInt64, normalized: Double)
    func display(_ id: UInt64, normalized: Double) -> String
    /// Puts the plug-in's own editor into `container`; completion gets its size, or nil when it
    /// has none (the generic editor is shown instead).
    func openEditor(in container: NSView, resize: @escaping (NSSize) -> Void, completion: @escaping (NSSize?) -> Void)
    /// The user resized the window: returns the size the editor accepts.
    func editorResized(to size: NSSize) -> NSSize
    var editorResizable: Bool { get }
    func closeEditor()
    func close()
}

// MARK: - Audio Unit

/// AUv2 / AUv3 effect hosted through AUAudioUnit. Out of process by default: macOS runs the
/// plug-in in its own service, so a crash there ends only that service.
final class AUPluginProcessor: PluginProcessor {
    let au: AUAudioUnit
    let channels: Int
    let outOfProcess: Bool
    private let renderBlock: AURenderBlock
    private var pull: AURenderPullInputBlock!
    private let inL, inR, outL, outR: UnsafeMutablePointer<Float>
    private let outList: UnsafeMutableAudioBufferListPointer
    private var sampleTime: Double = 0
    private var viewController: NSViewController?

    static func instantiate(_ d: AudioPluginDescriptor, outOfProcess: Bool,
                            completion: @escaping (Result<AUPluginProcessor, Error>) -> Void) {
        guard let ids = FourCC.parse(identifier: d.identifier) else {
            completion(.failure(PluginError("Invalid Audio Unit identifier \(d.identifier)"))); return
        }
        let desc = AudioComponentDescription(componentType: ids.type, componentSubType: ids.subtype,
                                             componentManufacturer: ids.manufacturer, componentFlags: 0, componentFlagsMask: 0)
        AUAudioUnit.instantiate(with: desc, options: outOfProcess ? [.loadOutOfProcess] : []) { au, error in
            DispatchQueue.main.async {
                guard let au else { completion(.failure(error ?? PluginError("The Audio Unit could not be created"))); return }
                do { completion(.success(try AUPluginProcessor(au: au, outOfProcess: outOfProcess))) } catch { completion(.failure(error)) }
            }
        }
    }

    private init(au: AUAudioUnit, outOfProcess: Bool) throws {
        self.au = au
        self.outOfProcess = outOfProcess
        guard au.outputBusses.count > 0 else { throw PluginError("The Audio Unit has no audio output") }
        guard au.inputBusses.count > 0 else { throw PluginError("The Audio Unit has no audio input (instrument or generator)") }
        func setFormat(_ ch: AVAudioChannelCount) -> Bool {
            guard let f = AVAudioFormat(standardFormatWithSampleRate: AudioMixerEngine.sampleRateHz, channels: ch) else { return false }
            do { try au.inputBusses[0].setFormat(f); try au.outputBusses[0].setFormat(f); return true } catch { return false }
        }
        if setFormat(2) { channels = 2 } else if setFormat(1) { channels = 1 } else {
            throw PluginError("The Audio Unit accepts neither stereo nor mono 48 kHz audio")
        }
        au.maximumFramesToRender = AUAudioFrameCount(AudioMixerEngine.maxFrames)
        try au.allocateRenderResources()
        renderBlock = au.renderBlock
        func alloc() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: AudioMixerEngine.maxFrames)
            p.initialize(repeating: 0, count: AudioMixerEngine.maxFrames)
            return p
        }
        inL = alloc(); inR = alloc(); outL = alloc(); outR = alloc()
        outList = AudioBufferList.allocate(maximumBuffers: channels)
        let ch = channels
        let inL = inL, inR = inR, silence = outR
        pull = { _, _, frameCount, bus, data in
            let list = UnsafeMutableAudioBufferListPointer(data)
            let n = Int(frameCount)
            for i in 0..<list.count {
                let src: UnsafeMutablePointer<Float> = i == 0 ? inL : inR
                let bytes = UInt32(n * MemoryLayout<Float>.size)
                if bus != 0 {
                    // Side-chain inputs get silence.
                    if let p = list[i].mData { memset(p, 0, Int(bytes)) } else { list[i].mData = UnsafeMutableRawPointer(silence) }
                } else if let p = list[i].mData {
                    memcpy(p, ch == 1 || i == 0 ? inL : src, Int(bytes))
                } else {
                    list[i].mData = UnsafeMutableRawPointer(src)
                }
                list[i].mDataByteSize = bytes
            }
            return noErr
        }
    }

    deinit {
        [inL, inR, outL, outR].forEach { $0.deallocate() }
        free(outList.unsafeMutablePointer)
    }

    var latencySamples: Int { Int((au.latency * AudioMixerEngine.sampleRateHz).rounded()) }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        if channels == 1 {
            for i in 0..<frames { inL[i] = 0.5 * (left[i] + right[i]) }
        } else {
            inL.update(from: left, count: frames)
            inR.update(from: right, count: frames)
        }
        let bytes = UInt32(frames * MemoryLayout<Float>.size)
        outList[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outL))
        if channels > 1 { outList[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: bytes, mData: UnsafeMutableRawPointer(outR)) }
        var flags = AudioUnitRenderActionFlags()
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        sampleTime += Double(frames)
        let status = renderBlock(&flags, &ts, AUAudioFrameCount(frames), 0, outList.unsafeMutablePointer, pull)
        guard status == noErr, let l = outList[0].mData?.assumingMemoryBound(to: Float.self) else { return false }
        left.update(from: l, count: frames)
        if channels > 1, let r = outList[1].mData?.assumingMemoryBound(to: Float.self) {
            right.update(from: r, count: frames)
        } else {
            right.update(from: l, count: frames)
        }
        return true
    }

    func state() -> Data? {
        guard let s = au.fullStateForDocument ?? au.fullState else { return nil }
        return try? PropertyListSerialization.data(fromPropertyList: s, format: .binary, options: 0)
    }

    func restore(_ data: Data) -> Bool {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return false }
        au.fullStateForDocument = dict
        return true
    }

    private var allParameters: [AUParameter] { au.parameterTree?.allParameters ?? [] }

    func parameters() -> [PluginParameter] {
        allParameters.filter { $0.flags.contains(.flag_IsWritable) }.prefix(128).map { p in
            let span = Double(p.maxValue - p.minValue)
            return PluginParameter(id: p.address, name: p.displayName, unit: p.unitName ?? "",
                                   value: span > 0 ? Double(p.value - p.minValue) / span : 0,
                                   steps: p.unit == .indexed || p.unit == .boolean ? Int(p.maxValue - p.minValue) : 0)
        }
    }

    func setParameter(_ id: UInt64, normalized: Double) {
        guard let p = au.parameterTree?.parameter(withAddress: id) else { return }
        p.setValue(p.minValue + AUValue(min(max(normalized, 0), 1)) * (p.maxValue - p.minValue), originator: nil)
    }

    func display(_ id: UInt64, normalized: Double) -> String {
        guard let p = au.parameterTree?.parameter(withAddress: id) else { return "" }
        var v = p.minValue + AUValue(normalized) * (p.maxValue - p.minValue)
        let s = p.string(fromValue: &v)
        return s.isEmpty ? String(format: "%.2f", v) : s
    }

    func openEditor(in container: NSView, resize: @escaping (NSSize) -> Void, completion: @escaping (NSSize?) -> Void) {
        au.requestViewController { [weak self] vc in
            DispatchQueue.main.async {
                guard let self, let vc else { completion(nil); return }
                self.viewController = vc
                let view = vc.view
                var size = vc.preferredContentSize
                if size.width < 50 || size.height < 50 { size = view.frame.size }
                if size.width < 50 || size.height < 50 { size = NSSize(width: 480, height: 320) }
                view.frame = NSRect(origin: .zero, size: size)
                view.autoresizingMask = [.width, .height]
                container.addSubview(view)
                completion(size)
            }
        }
    }

    func editorResized(to size: NSSize) -> NSSize { size }
    var editorResizable: Bool { true }

    func closeEditor() {
        viewController?.view.removeFromSuperview()
        viewController = nil
    }

    func close() {
        closeEditor()
        au.deallocateRenderResources()
    }
}

// MARK: - VST 3

/// VST 3 effect through the CVST3 host (in process).
final class VST3PluginProcessor: PluginProcessor {
    private let handle: OpaquePointer
    let channels: Int
    var outOfProcess: Bool { false }
    private var editorOpen = false
    private final class ResizeBox { var handler: ((NSSize) -> Void)? }
    private let resizeBox = ResizeBox()

    init(path: String, cid: String) throws {
        var err = [CChar](repeating: 0, count: 512)
        guard let h = lc_vst3_open(path, cid, AudioMixerEngine.sampleRateHz, Int32(AudioMixerEngine.maxFrames), &err, Int32(err.count)) else {
            throw PluginError(String(cString: err).isEmpty ? "The VST 3 plug-in could not be opened" : String(cString: err))
        }
        handle = h
        channels = Int(lc_vst3_channels(h))
    }

    var latencySamples: Int { Int(lc_vst3_latency(handle)) }

    func process(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int) -> Bool {
        lc_vst3_process(handle, left, right, Int32(frames)) == 0
    }

    func state() -> Data? {
        var ptr: UnsafeMutablePointer<UInt8>?
        var len: Int64 = 0
        guard lc_vst3_get_state(handle, &ptr, &len), let ptr else { return nil }
        defer { lc_vst3_free(ptr) }
        return Data(bytes: ptr, count: Int(len))
    }

    func restore(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return false }
            return lc_vst3_set_state(handle, base, Int64(raw.count))
        }
    }

    func parameters() -> [PluginParameter] {
        var out: [PluginParameter] = []
        let n = min(Int(lc_vst3_param_count(handle)), 256)
        var title = [CChar](repeating: 0, count: 128), units = [CChar](repeating: 0, count: 64)
        for i in 0..<n {
            var id: UInt32 = 0, steps: Int32 = 0, flags: Int32 = 0
            guard lc_vst3_param_info(handle, Int32(i), &id, &title, Int32(title.count), &units, Int32(units.count), &steps, &flags),
                  flags & 2 == 0, flags & 4 == 0 else { continue }
            out.append(PluginParameter(id: UInt64(id), name: String(cString: title), unit: String(cString: units),
                                       value: lc_vst3_param_get(handle, id), steps: Int(steps)))
            if out.count >= 128 { break }
        }
        return out
    }

    func setParameter(_ id: UInt64, normalized: Double) { lc_vst3_param_set(handle, UInt32(truncatingIfNeeded: id), min(max(normalized, 0), 1)) }

    func display(_ id: UInt64, normalized: Double) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        lc_vst3_param_display(handle, UInt32(truncatingIfNeeded: id), normalized, &buf, Int32(buf.count))
        return String(cString: buf)
    }

    func openEditor(in container: NSView, resize: @escaping (NSSize) -> Void, completion: @escaping (NSSize?) -> Void) {
        guard lc_vst3_has_editor(handle) else { completion(nil); return }
        resizeBox.handler = resize
        let cb: @convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void = { ctx, w, h in
            guard let ctx else { return }
            let box = Unmanaged<ResizeBox>.fromOpaque(ctx).takeUnretainedValue()
            box.handler?(NSSize(width: Int(w), height: Int(h)))
        }
        var w: Int32 = 0, h: Int32 = 0
        let ctx = Unmanaged.passUnretained(resizeBox).toOpaque()
        guard lc_vst3_editor_open(handle, Unmanaged.passUnretained(container).toOpaque(), &w, &h, cb, ctx) else {
            resizeBox.handler = nil
            completion(nil)
            return
        }
        editorOpen = true
        completion(NSSize(width: max(Int(w), 100), height: max(Int(h), 60)))
    }

    var editorResizable: Bool { editorOpen && lc_vst3_editor_can_resize(handle) }

    func editorResized(to size: NSSize) -> NSSize {
        guard editorOpen else { return size }
        var w = Int32(size.width), h = Int32(size.height)
        lc_vst3_editor_set_size(handle, &w, &h)
        return NSSize(width: Int(w), height: Int(h))
    }

    func closeEditor() {
        if editorOpen { lc_vst3_editor_close(handle) }
        editorOpen = false
        resizeBox.handler = nil
    }

    func close() {
        closeEditor()
        lc_vst3_close(handle)
    }
}

public struct PluginError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
#endif
