#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Multiview monitoring window: Preview and Program on top, every input below with its
/// number, name, status and tally (red = on Program, green = on Preview). Input tiles are the
/// engine's 10 fps thumbnails (384×216); Preview/Program are the full monitor feeds. Open it on
/// a second display for the director or a confidence monitor. Click = Preview, double-click = Cut.
struct MultiviewView: View {
    @EnvironmentObject var model: AppModel
    /// Tile arrangement (0.63.0), kept per Mac.
    @AppStorage("multiview.layout") private var layoutRaw = MultiviewLayout.standard.rawValue

    enum MultiviewLayout: String, CaseIterable {
        case standard, programBig, programTop, inputsLeft, grid, pvwPgm
        var title: String { L10n.t("multiview.layout.\(rawValue)") }
        var icon: String {
            switch self {
            case .standard: return "rectangle.split.2x2"
            case .programBig: return "rectangle.leadinghalf.inset.filled"
            case .programTop: return "rectangle.tophalf.inset.filled"
            case .inputsLeft: return "sidebar.left"
            case .grid: return "square.grid.3x3"
            case .pvwPgm: return "rectangle.split.2x1"
            }
        }
    }

    private var layout: MultiviewLayout { MultiviewLayout(rawValue: layoutRaw) ?? .standard }

    var body: some View {
        GeometryReader { geo in
            Group {
                switch layout {
                case .standard:
                    VStack(spacing: 4) {
                        HStack(spacing: 4) { previewTile(large: true); programTile(large: true) }
                        ScrollView { inputGrid(columns: geo.size.width > 1400 ? 5 : (geo.size.width > 900 ? 4 : 3)) }
                    }
                case .programBig:
                    HStack(alignment: .top, spacing: 4) {
                        programTile(large: true).frame(width: geo.size.width * 0.66)
                        VStack(spacing: 4) {
                            previewTile(large: false)
                            ScrollView { inputGrid(columns: 2) }
                        }
                    }
                case .programTop:
                    VStack(spacing: 4) {
                        HStack(spacing: 4) {
                            programTile(large: true)
                            previewTile(large: false).frame(width: geo.size.width * 0.28)
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(spacing: 4) {
                                ForEach(model.inputs) { info in inputTile(info).frame(width: max(160, geo.size.width / 7)) }
                            }
                        }
                        .frame(height: max(100, geo.size.width / 7 * 9 / 16 + 8))
                    }
                case .inputsLeft:
                    HStack(alignment: .top, spacing: 4) {
                        ScrollView { inputGrid(columns: 2) }.frame(width: geo.size.width * 0.34)
                        VStack(spacing: 4) { programTile(large: true); previewTile(large: true) }
                    }
                case .grid:
                    ScrollView {
                        let cols = geo.size.width > 1400 ? 4 : 3
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: cols), spacing: 4) {
                            previewTile(large: false)
                            programTile(large: false)
                            ForEach(model.inputs) { info in inputTile(info) }
                        }
                    }
                case .pvwPgm:
                    HStack(spacing: 4) { previewTile(large: true); programTile(large: true) }
                        .frame(maxHeight: .infinity)
                }
            }
            .padding(4)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(Color.black)
        .foregroundStyle(Theme.text)
        .overlay(alignment: .topTrailing) {
            Menu {
                ForEach(MultiviewLayout.allCases, id: \.self) { l in
                    Button { layoutRaw = l.rawValue } label: {
                        Label(l.title, systemImage: l == layout ? "checkmark" : l.icon)
                    }
                }
            } label: { Image(systemName: layout.icon) }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .padding(6)
            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .help(L10n.t("multiview.layout"))
        }
    }

    private func previewTile(large: Bool) -> some View {
        MultiviewTile(feed: model.previewFeed, label: label(model.switcher.preview, prefix: L10n.t("monitor.preview")),
                      tally: Theme.preview, large: large, aspect: model.canvasAspect)
    }

    private func programTile(large: Bool) -> some View {
        MultiviewTile(feed: model.programFeed, label: label(model.switcher.transition?.to ?? model.switcher.program,
                                                             prefix: L10n.t("monitor.program")),
                      tally: Theme.program, large: large, aspect: model.canvasAspect,
                      onAir: model.isStreamingActive || model.isRecording)
    }

    private func inputTile(_ info: ProductionEngine.InputInfo) -> some View {
        MultiviewTile(feed: model.feed(for: info.id), label: "\(info.number)  \(info.name)",
                      tally: tally(info.id), large: false, status: info.status)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.cutDirect(info.id) }
            .onTapGesture { model.preview(info.id) }
    }

    private func inputGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
            ForEach(model.inputs) { info in inputTile(info) }
        }
    }

    private func label(_ id: InputID?, prefix: String) -> String {
        guard let id, let i = model.inputs.first(where: { $0.id == id }) else { return "\(prefix) · \(L10n.t("monitor.no_input"))" }
        return "\(prefix) · \(i.number) \(i.name)"
    }

    private func tally(_ id: InputID) -> Color? {
        let s = model.switcher
        if s.program == id || s.transition?.from == id || s.transition?.to == id { return Theme.program }
        if s.preview == id { return Theme.preview }
        return nil
    }
}

struct MultiviewTile: View {
    let feed: FrameFeed
    let label: String
    let tally: Color?
    let large: Bool
    /// Program / preview follow the canvas (portrait, custom); input tiles stay 16:9.
    var aspect: Double = 16 / 9
    var onAir = false
    var status: SourceStatus = .live

    var body: some View {
        PixelBufferView(feed: feed)
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 6) {
                    Text(label).font(.system(size: large ? 14 : 11, weight: .bold)).lineLimit(1)
                    if !status.isHealthy && status != .starting {
                        Text(status.label).font(.system(size: 10)).foregroundStyle(Theme.warning).lineLimit(1)
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(tally ?? Color.black.opacity(0.65))
                .padding(4)
            }
            .overlay(alignment: .topTrailing) {
                if onAir {
                    Text("ON AIR").font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.program).padding(4)
                }
            }
            .overlay(Rectangle().stroke(tally ?? Color.white.opacity(0.15), lineWidth: tally == nil ? 1 : 3))
    }
}
#endif
