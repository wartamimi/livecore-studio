#if os(macOS)
import AppKit
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices
import SwiftUI

/// "Online Library by Pixabay" (0.61.0): search free photos, illustrations, vectors and videos on
/// Pixabay with the operator's own API key (kept in the Keychain), pick one or more, and each is
/// downloaded once and added as an image or video input.
struct PixabaySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var apiKey = ""
    @State private var hasKey = PixabaySheet.storedKey() != nil
    @State private var editingKey = PixabaySheet.storedKey() == nil
    @AppStorage("pixabay.kind") private var kindRaw = Pixabay.Kind.photo.rawValue
    @State private var query = ""
    @State private var hits: [Pixabay.Hit] = []
    @State private var total = 0
    @State private var page = 1
    @State private var searching = false
    @State private var selected: [Int] = []
    @State private var adding = false
    @State private var progress = ""
    @State private var error: String?

    private var kind: Pixabay.Kind { Pixabay.Kind(rawValue: kindRaw) ?? .photo }

    static func storedKey() -> String? {
        guard let k = (try? KeychainStore.load(account: Pixabay.keychainAccount)) ?? nil, !k.isEmpty else { return nil }
        return k
    }

    static var downloadFolder: URL {
        AppSupport.folder("Pixabay")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            DialogTitle("photo.on.rectangle.angled", L10n.t("pixabay.title"))
            keyRow
            HStack {
                Picker("", selection: $kindRaw) {
                    Text(L10n.t("pixabay.photo")).tag(Pixabay.Kind.photo.rawValue)
                    Text(L10n.t("pixabay.illustration")).tag(Pixabay.Kind.illustration.rawValue)
                    Text(L10n.t("pixabay.vector")).tag(Pixabay.Kind.vector.rawValue)
                    Text(L10n.t("pixabay.video")).tag(Pixabay.Kind.video.rawValue)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 380)
                .onChange(of: kindRaw) { _ in if !query.isEmpty { search(reset: true) } }
                TextField(L10n.t("pixabay.search_hint"), text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search(reset: true) }
                Button(L10n.t("pixabay.search")) { search(reset: true) }
                    .disabled(!hasKey || searching)
            }
            ZStack {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(hits) { h in tile(h) }
                    }
                    .padding(2)
                    if hits.count < total && !hits.isEmpty {
                        Button(L10n.t("pixabay.more")) { search(reset: false) }.disabled(searching).padding(.vertical, 6)
                    }
                }
                if searching && hits.isEmpty { ProgressView() }
                if !searching && hits.isEmpty {
                    Text(hasKey ? L10n.t("pixabay.empty") : L10n.t("pixabay.need_key"))
                        .font(.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.center).padding()
                }
            }
            .frame(minHeight: 320)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.warning) }
            HStack {
                // Pixabay asks apps to show where the media comes from.
                Link(L10n.t("pixabay.attribution"), destination: URL(string: "https://pixabay.com/")!).font(.caption)
                Spacer()
                if adding { ProgressView().controlSize(.small); Text(progress).font(.caption) }
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(selected.count > 1 ? L10n.f("pixabay.add_n", String(selected.count)) : L10n.t("pixabay.add")) { addSelected() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || adding)
            }
        }
        .padding(16)
        .frame(width: 780, height: 600)
    }

    @ViewBuilder private var keyRow: some View {
        if editingKey {
            HStack {
                SecureField(L10n.t("pixabay.key"), text: $apiKey).textFieldStyle(.roundedBorder)
                Button(L10n.t("pixabay.save_key")) {
                    let k = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !k.isEmpty else { return }
                    do {
                        try KeychainStore.save(streamKey: k, account: Pixabay.keychainAccount)
                        hasKey = true; editingKey = false; apiKey = ""; error = nil
                    } catch { self.error = error.localizedDescription }
                }
                Link(L10n.t("pixabay.get_key"), destination: Pixabay.apiDocs).font(.caption)
            }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "key.fill").foregroundStyle(Theme.textDim)
                Text(L10n.t("pixabay.key_saved")).font(.caption).foregroundStyle(Theme.textDim)
                Button(L10n.t("pixabay.change_key")) { editingKey = true }.buttonStyle(.link).font(.caption)
            }
        }
    }

    private func tile(_ h: Pixabay.Hit) -> some View {
        let isOn = selected.contains(h.id)
        return VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: h.thumbnailURL) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) }
                    else { Rectangle().fill(Theme.panelRaised) }
                }
                .frame(height: 96).frame(maxWidth: .infinity).clipped()
                if h.isVideo {
                    Text(h.duration.map { TimerMath.duration(Double($0)) } ?? "▶")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .padding(.horizontal, 4).background(.black.opacity(0.7)).foregroundStyle(.white).padding(4)
                }
            }
            Text(h.tags).font(.system(size: 10)).lineLimit(1)
            Text("\(h.width)×\(h.height) · \(h.user)").font(.system(size: 9)).foregroundStyle(Theme.textDim).lineLimit(1)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isOn ? Theme.preview.opacity(0.25) : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(isOn ? Theme.preview : Theme.border, lineWidth: isOn ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture {
            if let i = selected.firstIndex(of: h.id) { selected.remove(at: i) } else { selected.append(h.id) }
        }
        .help(h.tags)
    }

    private func search(reset: Bool) {
        guard let key = Self.storedKey() else { error = Pixabay.Failure.noKey.description; return }
        let q = query, k = kind, nextPage = reset ? 1 : page + 1
        searching = true; error = nil
        if reset { hits = []; selected = []; total = 0 }
        Task {
            let r = await Pixabay.search(key: key, query: q, kind: k, page: nextPage)
            await MainActor.run {
                searching = false
                switch r {
                case let .success(p):
                    page = nextPage; total = p.total
                    let known = Set(hits.map(\.id))
                    hits += p.hits.filter { !known.contains($0.id) }
                    if hits.isEmpty { error = L10n.t("pixabay.no_results") }
                case let .failure(f):
                    error = f.description
                    if f == .badKey { editingKey = true }
                }
            }
        }
    }

    private func addSelected() {
        let picks = selected.compactMap { id in hits.first { $0.id == id } }
        guard !picks.isEmpty else { return }
        adding = true; error = nil
        Task {
            var failures: [String] = []
            for (n, h) in picks.enumerated() {
                await MainActor.run { progress = L10n.f("pixabay.downloading", String(n + 1), String(picks.count)) }
                switch await Pixabay.download(h, into: Self.downloadFolder) {
                case let .success(url):
                    await MainActor.run {
                        if h.isVideo { model.addVideoInput(url) } else { model.addImageInput(url) }
                    }
                case let .failure(f):
                    failures.append(f.description)
                }
            }
            await MainActor.run {
                adding = false
                if failures.isEmpty { dismiss() } else { error = failures.joined(separator: "\n"); selected = [] }
            }
        }
    }
}
#endif
