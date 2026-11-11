#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Sheet opened from an "add input" menu. Shown by the main window (`addInputSheets()`), so the
/// add menu works the same from the Inputs panel and from ADD INPUT in the bottom bar (0.55.0).
public enum AddInputSheet: Identifiable, Equatable {
    case title, timer, frame, qr, virtualSet, flag, pixabay, browser, capture, ndi, srt, decklink, captureCard, slideshow
    case subtitles(InputID), scene(InputID), liveCall(InputID)

    public var id: String {
        switch self {
        case let .subtitles(i): return "sub:" + i.raw
        case let .scene(i): return "scene:" + i.raw
        case let .liveCall(i): return "live:" + i.raw
        default: return "\(self)"
        }
    }
}

/// Every kind of input, grouped, each with the icon its tile shows.
struct AddInputMenuItems: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // One entry for every camera, capture card and iPhone (0.46.0, like vMix's "Video
        // Capture Device"): the device, format and audio are picked in the sheet.
        Section(L10n.t("inputs.camera_group")) {
            Button { model.refreshDevices(); model.addInputSheet = .captureCard } label: {
                Label(L10n.t("inputs.video_capture"), systemImage: "video")
            }
        }
        // Media files grouped in one place: video, video playlist, image, slideshow, presentation.
        Section(L10n.t("inputs.media_group")) {
            Button { model.addMedia() } label: { Label(L10n.t("media.add"), systemImage: "film") }
            Button { model.addMediaPlaylist() } label: { Label(L10n.t("media.add_playlist"), systemImage: "film.stack") }
            Button { model.addImage() } label: { Label(L10n.t("inputs.image"), systemImage: "photo") }
            Button { model.addInputSheet = .slideshow } label: { Label(L10n.t("slideshow.add"), systemImage: "photo.stack") }
            Button { model.addInputSheet = .pixabay } label: { Label(L10n.t("pixabay.menu"), systemImage: "photo.on.rectangle.angled") }
            Button { model.addPresentation() } label: { Label(L10n.t("presentation.add"), systemImage: "rectangle.on.rectangle.angled") }
        }
        Section(L10n.t("inputs.graphics_group")) {
            // Titles, lower thirds and running text are all made in the Title Designer.
            Button { model.addInputSheet = .title } label: { Label(L10n.t("inputs.title_menu"), systemImage: "textformat") }
            Button { model.addInputSheet = .timer } label: { Label(L10n.t("timer.add"), systemImage: "timer") }
            Button { model.addInputSheet = .frame } label: { Label(L10n.t("frame.add"), systemImage: "person.crop.rectangle") }
            Button { model.addInputSheet = .virtualSet } label: { Label(L10n.t("vset.add"), systemImage: "person.and.background.dotted") }
            Button { model.addInputSheet = .qr } label: { Label(L10n.t("qr.add"), systemImage: "qrcode") }
            Button { model.addInputSheet = .flag } label: { Label(L10n.t("flag.add"), systemImage: "flag") }
            Button { if let id = model.addTranscription() { model.addInputSheet = .subtitles(id) } } label: { Label(L10n.t("transcription.add"), systemImage: "captions.bubble") }
            Button { if let id = model.addScene() { model.addInputSheet = .scene(id) } } label: { Label(L10n.t("scene.new"), systemImage: "square.on.square") }
        }
        Section(L10n.t("inputs.other_group")) {
            Button { if let id = model.addLiveCall() { model.addInputSheet = .liveCall(id) } } label: {
                Label("LCS Live", systemImage: "person.wave.2")
            }
            Button { model.addInputSheet = .browser } label: { Label(L10n.t("browser.add"), systemImage: "globe") }
            if !model.isOperatorMode {
                Button { model.addInputSheet = .capture } label: { Label(L10n.t("capture.add"), systemImage: "macwindow") }
                Button { model.addInputSheet = .ndi } label: { Label(L10n.t("ndi.add"), systemImage: "antenna.radiowaves.left.and.right") }
                Button { model.addInputSheet = .srt } label: { Label(L10n.t("srtin.add"), systemImage: "dot.radiowaves.up.forward") }
                Button { model.addInputSheet = .decklink } label: { Label(L10n.t("decklink.add"), systemImage: "rectangle.connected.to.line.below") }
                Button { model.addColorBars() } label: { Label(L10n.t("inputs.colorbars"), systemImage: "chart.bar.fill") }
            }
        }
        Menu {
            Button("Black") { model.addColor(.black, name: "Black") }
            Button("White") { model.addColor(.white, name: "White") }
            Button("Blue") { model.addColor(NSColor(calibratedRed: 0.05, green: 0.2, blue: 0.55, alpha: 1), name: "Blue") }
            Button("Green screen") { model.addColor(NSColor(calibratedRed: 0, green: 0.7, blue: 0.25, alpha: 1), name: "Green") }
        } label: { Label(L10n.t("inputs.color"), systemImage: "paintpalette") }
    }
}

extension View {
    /// Presents the sheets the add-input menus ask for.
    func addInputSheets(_ model: AppModel) -> some View {
        dialog(item: Binding(get: { model.addInputSheet }, set: { model.addInputSheet = $0 }), model) { s in
            AddInputSheetView(sheet: s)
        }
    }
}

private struct AddInputSheetView: View {
    let sheet: AddInputSheet
    var body: some View {
        switch sheet {
        case .title: TitleSheet(editing: nil)
        case .timer: TimerSheet(editing: nil)
        case .frame: FrameSheet(editing: nil)
        case .qr: QRCodeSheet(editing: nil)
        case .virtualSet: VirtualSetSheet(editing: nil)
        case .flag: FlagSheet()
        case .pixabay: PixabaySheet()
        case .browser: BrowserSheet(editing: nil)
        case .capture: CaptureSheet(editing: nil)
        case .ndi: NDIInputSheet(editing: nil)
        case .srt: SRTInputSheet(editing: nil)
        case .decklink: DeckLinkInputSheet(editing: nil)
        case .captureCard: CaptureCardSheet(editing: nil)
        case .slideshow: SlideshowSheet(editing: nil)
        case let .subtitles(id): SubtitleSheet(input: id)
        case let .scene(id): SceneEditorSheet(input: id)
        case let .liveCall(id): LiveCallSheet(input: id)
        }
    }
}
#endif
