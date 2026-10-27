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

    var body: some View {
        GeometryReader { geo in
            let columns = geo.size.width > 1400 ? 5 : (geo.size.width > 900 ? 4 : 3)
            VStack(spacing: 4) {
                HStack(spacing: 4) {
                    MultiviewTile(feed: model.previewFeed, label: label(model.switcher.preview, prefix: L10n.t("monitor.preview")),
                                  tally: Theme.preview, large: true)
                    MultiviewTile(feed: model.programFeed, label: label(model.switcher.transition?.to ?? model.switcher.program,
                                                                         prefix: L10n.t("monitor.program")),
                                  tally: Theme.program, large: true,
                                  onAir: model.isStreamingActive || model.isRecording)
                }
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4) {
                        ForEach(model.inputs) { info in
                            MultiviewTile(feed: model.feed(for: info.id), label: "\(info.number)  \(info.name)",
                                          tally: tally(info.id), large: false, status: info.status)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { model.cutDirect(info.id) }
                                .onTapGesture { model.preview(info.id) }
                        }
                    }
                }
            }
            .padding(4)
        }
        .background(Color.black)
        .foregroundStyle(Theme.text)
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
    var onAir = false
    var status: SourceStatus = .live

    var body: some View {
        PixelBufferView(feed: feed)
            .aspectRatio(16 / 9, contentMode: .fit)
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
