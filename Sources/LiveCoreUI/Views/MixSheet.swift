#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Mix input window (0.79.0): its own Preview / Program, CUT and FADE, and where its Program goes.
/// Click an input to put it on the Mix Preview, double-click to cut it straight to the Mix Program.
struct MixSheet: View {
    let input: InputID
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var duration = 0.5

    private var state: SwitcherSnapshot { model.mixStates[input] ?? SwitcherSnapshot() }
    private var name: String { model.inputs.first { $0.id == input }?.name ?? L10n.t("mix.title") }

    var body: some View {
        VStack(spacing: 0) {
            DialogHeader(icon: "rectangle.split.2x1", title: name, subtitle: L10n.t("mix.subtitle"), close: { dismiss() })
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    monitor(L10n.t("monitor.preview"), state.preview, Theme.preview)
                    monitor(L10n.t("monitor.program"), input, Theme.program)
                }
                HStack(spacing: 8) {
                    Button(L10n.t("transition.cut")) { model.mixCut(input) }
                        .buttonStyle(StudioButtonStyle(color: Theme.program, active: true)).frame(width: 90)
                    Button(L10n.t("mix.fade")) { model.mixFade(input) }
                        .buttonStyle(StudioButtonStyle(color: Theme.accent, active: state.transition != nil)).frame(width: 90)
                    Stepper(String(format: "%.1f s", duration), value: $duration, in: 0.1...5, step: 0.1)
                        .onChange(of: duration) { model.engine?.setMixDuration(input, $0) }
                    Spacer()
                }
                SectionHeader(title: L10n.t("inputs.title"))
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(model.mixableInputs) { i in inputButton(i) }
                    }
                }
                .frame(minHeight: 90, maxHeight: 200)
                SectionHeader(title: L10n.t("mix.send_to"))
                HStack(spacing: 6) {
                    ForEach(1...OutputRouting.count, id: \.self) { n in
                        let on = model.outputRouting.slot(n).source == .input(input)
                        Button(L10n.f("mix.output_n", n)) { model.setOutputSource(n, on ? .program : .input(input)) }
                            .buttonStyle(StudioButtonStyle(color: Theme.accent, active: on))
                            .help(L10n.t("mix.output_help"))
                    }
                    Button(L10n.t("mix.iso")) { model.toggleISO(input) }
                        .buttonStyle(StudioButtonStyle(color: Theme.program, active: model.multiCorder.inputs.contains(input)))
                        .help(L10n.t("mix.iso_help"))
                }
            }
            .padding(14)
        }
        .frame(width: 620)
        .onAppear { duration = model.engine?.mixDuration(input) ?? 0.5 }
    }

    private func monitor(_ label: String, _ id: InputID?, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
            ZStack {
                Color.black
                if let id { PixelBufferView(feed: model.feed(for: id), transparent: true) }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(RoundedRectangle(cornerRadius: Theme.radiusS).stroke(color, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS))
        }
    }

    private func inputButton(_ i: ProductionEngine.InputInfo) -> some View {
        let onProgram = state.program == i.id, onPreview = state.preview == i.id
        return Text("\(i.number)  \(i.name)")
            .font(.system(size: 11, weight: .semibold)).lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background(onProgram ? Theme.program : onPreview ? Theme.preview : Theme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radiusS))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { model.mixPreview(input, i.id); model.mixCut(input) }
            .onTapGesture { model.mixPreview(input, i.id) }
    }
}
#endif
