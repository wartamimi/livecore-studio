#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Texts of an imported vMix GT title, with a preview of the finished title.
struct GTTitleSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var texts: [String: String] = [:]

    private var source: GTTitleSource? { model.gtTitleSource(input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.t("gt.edit_title")).font(.headline)
            if let s = source {
                Text(s.url.lastPathComponent).font(.caption).foregroundStyle(.secondary)
                if let img = preview(s.template) {
                    Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity).background(Color.black.opacity(0.6))
                }
                Form {
                    ForEach(s.template.textFields, id: \.self) { f in
                        TextField(f, text: Binding(get: { texts[f] ?? "" }, set: { texts[f] = $0 }))
                    }
                }
                Text(L10n.t("gt.note")).font(.caption).foregroundStyle(.secondary)
            } else {
                Text(L10n.t("gt.missing"))
            }
            HStack {
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    model.updateGTTitle(input, fields: texts)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(source == nil)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            guard let s = source else { return }
            for f in s.template.textFields { texts[f] = s.text(f) }
        }
    }

    private func preview(_ t: GTTemplate) -> CGImage? {
        let w = 480, h = max(1, Int(480 * t.height / max(t.width, 1)))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue) else { return nil }
        GTRenderer.draw(t, fields: texts, in: ctx, width: Double(w), height: Double(h), elapsed: nil)
        return ctx.makeImage()
    }
}
#endif
