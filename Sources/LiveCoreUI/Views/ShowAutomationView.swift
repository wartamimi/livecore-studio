#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Production ▸ Show Automation (0.71.0): safe slate and auto-director, saved in the project.
public struct ShowAutomationWindow: View {
    @EnvironmentObject var model: AppModel

    public init() {}

    public var body: some View {
        Form {
            Section {
                Toggle(L10n.t("slate.enable"), isOn: $model.safeSlate.enabled)
                inputPicker(L10n.t("slate.input"), $model.safeSlate.slate)
                Stepper(value: $model.safeSlate.delaySeconds, in: 0.5 ... 30, step: 0.5) {
                    Text(L10n.f("slate.delay", String(format: "%.1f", model.safeSlate.delaySeconds)))
                }
                Toggle(L10n.t("slate.auto_return"), isOn: $model.safeSlate.autoReturn)
                if model.safeSlate.autoReturn {
                    Stepper(value: $model.safeSlate.returnSeconds, in: 0.5 ... 60, step: 0.5) {
                        Text(L10n.f("slate.return_delay", String(format: "%.1f", model.safeSlate.returnSeconds)))
                    }
                }
                if let r = model.safeSlateReplaced {
                    Label(L10n.f("slate.active", model.inputs.first { $0.id == r }?.name ?? "?"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Text(L10n.t("slate.help")).font(.caption).foregroundStyle(Theme.textDim)
            } header: { Text(L10n.t("slate.title")) }

            Section {
                Toggle(L10n.t("director.enable"), isOn: Binding(get: { model.autoDirector.enabled },
                                                                set: { model.setAutoDirector(enabled: $0) }))
                ForEach($model.autoDirector.pairs) { $p in
                    HStack {
                        Picker("", selection: $p.channel) {
                            if !model.audioChannels.contains(where: { $0.id == p.channel }) { Text(L10n.t("macro.choose")).tag(p.channel) }
                            ForEach(model.audioChannels) { c in Text(c.name).tag(c.id) }
                        }
                        .labelsHidden().frame(width: 200)
                        Image(systemName: "arrow.right").foregroundStyle(Theme.textDim)
                        inputPicker("", $p.input).frame(width: 220)
                        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
                            let lv = model.meters.levels[p.channel]
                            let db = lv.map { Double(max($0.l, $0.r)) } ?? -120
                            Circle().fill(db >= model.autoDirector.thresholdDB ? Color.green : Color.gray.opacity(0.4))
                                .frame(width: 9, height: 9).help(String(format: "%.0f dB", db))
                        }
                        Spacer()
                        Button {
                            let id = p.id
                            model.autoDirector.pairs.removeAll { $0.id == id }
                        } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                    }
                }
                Button { addPair() } label: { Label(L10n.t("director.add_pair"), systemImage: "plus") }
                inputPicker(L10n.t("director.wide"), $model.autoDirector.wideInput, allowNone: true)
                Stepper(value: $model.autoDirector.thresholdDB, in: -70 ... -10, step: 1) {
                    Text(L10n.f("director.threshold", Int(model.autoDirector.thresholdDB)))
                }
                Stepper(value: $model.autoDirector.talkSeconds, in: 0.2 ... 5, step: 0.1) {
                    Text(L10n.f("director.talk", String(format: "%.1f", model.autoDirector.talkSeconds)))
                }
                Stepper(value: $model.autoDirector.minHoldSeconds, in: 1 ... 60, step: 0.5) {
                    Text(L10n.f("director.hold", String(format: "%.1f", model.autoDirector.minHoldSeconds)))
                }
                Stepper(value: $model.autoDirector.silenceToWideSeconds, in: 0 ... 120, step: 1) {
                    Text(L10n.f("director.silence", Int(model.autoDirector.silenceToWideSeconds)))
                }
                Toggle(L10n.t("director.transition"), isOn: $model.autoDirector.useTransition)
                Text(L10n.t("director.help")).font(.caption).foregroundStyle(Theme.textDim)
            } header: { Text(L10n.t("director.title")) }
        }
        .formStyle(.grouped)
    }

    private func addPair() {
        let used = Set(model.autoDirector.pairs.map(\.channel))
        let ch = model.audioChannels.first { !used.contains($0.id) }?.id ?? model.audioChannels.first?.id ?? ""
        model.autoDirector.pairs.append(.init(channel: ch, input: nil))
    }

    private func inputPicker(_ title: String, _ b: Binding<InputID?>, allowNone: Bool = true) -> some View {
        Picker(title, selection: b) {
            if allowNone { Text(L10n.t("automation.none")).tag(InputID?.none) }
            ForEach(model.inputs) { i in Text("\(i.number)  \(i.name)").tag(InputID?.some(i.id)) }
        }
    }
}
#endif
