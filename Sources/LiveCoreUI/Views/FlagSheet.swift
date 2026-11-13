#if os(macOS)
import AppKit
import LiveCoreServices
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import LiveCoreCore
import LiveCoreEngine

/// Country flags bundled with the app (0.51.0): public-domain Wikipedia flags, 1920 px PNG,
/// original proportions. See Sources/LiveCoreUI/Flags/SOURCE.txt.
enum FlagLibrary {
    struct Flag: Identifiable, Hashable { let code: String; let name: String; var id: String { code } }

    static let folder: URL? = L10n.bundle.url(forResource: "Flags", withExtension: nil)

    static let all: [Flag] = {
        guard let url = folder?.appendingPathComponent("countries.json"),
              let data = try? Data(contentsOf: url),
              let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [] }
        return map.map { Flag(code: $0.key.lowercased(), name: $0.value) }
            .filter { FileManager.default.fileExists(atPath: imageURL($0.code)?.path ?? "") }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }()

    static func imageURL(_ code: String) -> URL? { folder?.appendingPathComponent("\(code).png") }

    private static var thumbs: [String: NSImage] = [:]
    /// Small decoded thumbnail (the 1920 px originals would cost ~10 MB each in the grid).
    static func thumbnail(_ code: String) -> NSImage? {
        if let t = thumbs[code] { return t }
        guard let url = imageURL(code), let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                   kCGImageSourceThumbnailMaxPixelSize: 160] as CFDictionary)
        else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbs[code] = img
        return img
    }

    /// Copies the flag to Application Support so the input keeps working when the app moves.
    static func stableCopy(_ code: String) -> URL? {
        guard let src = imageURL(code) else { return nil }
        let dir = AppSupport.folder("Flags")
        let dst = dir.appendingPathComponent("\(code).png")
        if FileManager.default.fileExists(atPath: dst.path) { return dst }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: src, to: dst)
            return dst
        } catch { return src }
    }
}

extension AppModel {
    /// A flag as an image input named "Flag – Country", optionally waving.
    @discardableResult
    func addFlag(_ flag: FlagLibrary.Flag, wave: InputWave?) -> InputID? {
        guard let engine, let url = FlagLibrary.stableCopy(flag.code) else { return nil }
        let id = engine.addImage(url: url)
        engine.renameInput(id, to: "Flag – \(flag.name)")
        if let wave {
            var a = adjust(of: id)
            a.wave = wave
            a.wave.enabled = true
            setAdjust(id, a)
        }
        return id
    }
}

struct FlagSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: FlagLibrary.Flag?
    @State private var animate = true
    @State private var wave = InputWave()

    private var flags: [FlagLibrary.Flag] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return FlagLibrary.all }
        return FlagLibrary.all.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.code.caseInsensitiveCompare(q) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DialogTitle("flag", "Flags of the world")
            TextField("Search country or code (e.g. Indonesia, ID)", text: $query).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                    ForEach(flags) { f in
                        VStack(spacing: 3) {
                            if let img = FlagLibrary.thumbnail(f.code) {
                                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).frame(height: 52)
                            }
                            Text(f.name).font(.system(size: 10)).lineLimit(1)
                        }
                        .padding(4)
                        .frame(maxWidth: .infinity)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(selected == f ? Color.accentColor.opacity(0.35) : Color.clear))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { selected = f; add() }
                        .onTapGesture { selected = f }
                    }
                }
            }
            .frame(height: 330)
            Toggle("Animate (waving flag)", isOn: $animate)
            if animate {
                LabeledContent("Wave height") { Slider(value: $wave.amplitude, in: 0.01...0.12) }
                LabeledContent("Waves") { Slider(value: $wave.frequency, in: 0.5...3) }
                LabeledContent("Speed") { Slider(value: $wave.speed, in: 0.1...2) }
                LabeledContent("Shading") { Slider(value: $wave.shading, in: 0...1) }
            }
            Text("Public-domain flags (Wikipedia), original proportions. Animation and mask can be changed later in Properties › Colour, Orientation & Mask.")
                .font(.caption).foregroundStyle(Theme.textDim)
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(16)
        .frame(width: 600)
    }

    private func add() {
        guard let f = selected else { return }
        model.addFlag(f, wave: animate ? wave : nil)
        dismiss()
    }
}

/// Mask and waving-flag controls of an input (0.51.0), shown in Colour, Orientation & Mask.
struct MaskWaveSection: View {
    @Binding var adjust: InputAdjust

    var body: some View {
        Section("Mask") {
            Picker("Shape", selection: $adjust.mask.shape) {
                ForEach(InputMask.Shape.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            switch adjust.mask.shape {
            case .rectangle, .ellipse:
                slider("Left", $adjust.mask.x, -0.5...1)
                slider("Top", $adjust.mask.y, -0.5...1)
                slider("Width", $adjust.mask.width, 0.01...1.5)
                slider("Height", $adjust.mask.height, 0.01...1.5)
                if adjust.mask.shape == .rectangle { slider("Corner radius", $adjust.mask.radius, 0...0.5) }
                slider("Soft edge", $adjust.mask.feather, 0...0.25)
                Toggle("Invert", isOn: $adjust.mask.invert)
            case .imageLuma, .imageAlpha:
                LabeledContent("Image") {
                    Text((adjust.mask.imagePath as NSString?)?.lastPathComponent ?? "none").lineLimit(1)
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.allowedContentTypes = [.image]
                        if p.runModal() == .OK, let u = p.url { adjust.mask.imagePath = u.path }
                    }
                }
                Toggle("Invert", isOn: $adjust.mask.invert)
            case .none:
                EmptyView()
            }
        }
        Section("Wave (flag animation)") {
            Toggle("Waving", isOn: $adjust.wave.enabled)
            if adjust.wave.enabled {
                slider("Wave height", $adjust.wave.amplitude, 0.01...0.12)
                slider("Waves", $adjust.wave.frequency, 0.5...3)
                slider("Speed", $adjust.wave.speed, 0.1...2)
                slider("Shading", $adjust.wave.shading, 0...1)
            }
        }
    }

    private func slider(_ label: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        LabeledContent(label) {
            Slider(value: v, in: r)
            Text(String(format: "%.2f", v.wrappedValue)).monospacedDigit().frame(width: 42, alignment: .trailing)
        }
    }
}
#endif
