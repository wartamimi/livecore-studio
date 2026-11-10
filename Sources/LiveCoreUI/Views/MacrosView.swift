#if os(macOS)
import LiveCoreCore
import LiveCoreEngine
import SwiftUI

/// Production ▸ Macros (0.65.0): the macro list with ▶ buttons on the left, the selected macro's
/// steps and triggers on the right.
struct MacrosWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 250)
                Divider()
                if let id = selection, let k = model.macroBook.macros.firstIndex(where: { $0.id == id }) {
                    MacroEditor(index: k).id(id)
                } else {
                    VStack(spacing: 8) {
                        Text(L10n.t("macro.empty")).foregroundStyle(Theme.textDim)
                        Button(L10n.t("macro.new")) { selection = model.addMacro() }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .onAppear { if selection == nil { selection = model.macroBook.macros.first?.id } }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button { selection = model.addMacro() } label: { Label(L10n.t("macro.new"), systemImage: "plus") }
            Toggle(L10n.t("macro.triggers_on"), isOn: $model.macroTriggersEnabled).toggleStyle(.switch).controlSize(.small)
            if model.macroTriggersTripped {
                Label(L10n.t("macro.loop_stopped"), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Button(L10n.t("macro.rearm")) { model.rearmMacroTriggers() }
            }
            Spacer()
            Button(L10n.t("macro.stop_all")) { model.stopAllMacros() }.disabled(model.runningMacros.isEmpty)
        }
        .padding(10)
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(model.macroBook.macros.enumerated()), id: \.element.id) { k, m in
                HStack(spacing: 6) {
                    Text("M\(k + 1)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                        .foregroundStyle(k < MacroBook.maxNumber ? Theme.text : Theme.textDim)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.name).lineLimit(1)
                        let trig = m.triggers.filter(\.enabled).count
                        Text(L10n.f("macro.summary", m.steps.count, trig)).font(.system(size: 10)).foregroundStyle(Theme.textDim)
                    }
                    Spacer()
                    let running = model.runningMacros.contains(m.id)
                    Button { running ? model.stopMacro(m.id) : model.runMacro(m.id) } label: {
                        Image(systemName: running ? "stop.fill" : "play.fill").foregroundStyle(running ? Theme.program : Theme.preview)
                    }
                    .buttonStyle(.borderless)
                    .help(running ? L10n.t("macro.stop") : L10n.t("macro.run"))
                }
                .tag(m.id)
                .contextMenu {
                    Button(L10n.t("macro.run")) { model.runMacro(m.id) }
                    Button(L10n.t("macro.duplicate")) { model.duplicateMacro(m.id) }
                    Button(L10n.t("macro.move_up")) { model.moveMacro(m.id, by: -1) }.disabled(k == 0)
                    Button(L10n.t("macro.move_down")) { model.moveMacro(m.id, by: 1) }.disabled(k == model.macroBook.macros.count - 1)
                    Divider()
                    Button(L10n.t("macro.delete"), role: .destructive) {
                        if selection == m.id { selection = nil }
                        model.deleteMacro(m.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// Steps and triggers of one macro.
private struct MacroEditor: View {
    @EnvironmentObject var model: AppModel
    let index: Int

    private var macro: Binding<Macro> {
        Binding(get: { model.macroBook.macros.indices.contains(index) ? model.macroBook.macros[index] : Macro(name: "") },
                set: { if model.macroBook.macros.indices.contains(index) { model.macroBook.macros[index] = $0 } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    TextField(L10n.t("macro.name"), text: macro.name).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                    Text(L10n.f("macro.number", index + 1)).foregroundStyle(Theme.textDim)
                    Spacer()
                    Button { model.runMacro(macro.wrappedValue.id) } label: { Label(L10n.t("macro.run"), systemImage: "play.fill") }
                        .disabled(model.runningMacros.contains(macro.wrappedValue.id))
                }
                GroupBox(L10n.t("macro.steps")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if macro.wrappedValue.steps.isEmpty { Text(L10n.t("macro.no_steps")).foregroundStyle(Theme.textDim) }
                        ForEach(Array(macro.wrappedValue.steps.enumerated()), id: \.element.id) { k, _ in stepRow(k) }
                        Menu { stepKindItems { kind in addStep(kind) } } label: { Label(L10n.t("macro.add_step"), systemImage: "plus") }
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                GroupBox(L10n.t("macro.triggers")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if macro.wrappedValue.triggers.isEmpty { Text(L10n.t("macro.no_triggers")).foregroundStyle(Theme.textDim) }
                        ForEach(Array(macro.wrappedValue.triggers.enumerated()), id: \.element.id) { k, _ in triggerRow(k) }
                        Menu {
                            ForEach(MacroTriggerEvent.allCases, id: \.self) { e in
                                Button(L10n.t("macro.event.\(e.rawValue)")) {
                                    macro.wrappedValue.triggers.append(MacroTrigger(e, time: e == .timeOfDay ? "19:00" : nil))
                                }
                            }
                        } label: { Label(L10n.t("macro.add_trigger"), systemImage: "bolt.fill") }
                            .fixedSize()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                Text(L10n.t("macro.help")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    // MARK: Steps

    @ViewBuilder private func stepKindItems(_ pick: @escaping (MacroStepKind) -> Void) -> some View {
        let groups: [[MacroStepKind]] = [
            [.cut, .auto, .transition, .program, .preview],
            [.overlayOn, .overlayOff, .overlayToggle],
            [.audioOn, .audioOff, .audioFade],
            [.videoPlay, .videoPause, .videoRestart],
            [.wait, .runMacro],
            [.streamStart, .streamStop, .recordStart, .recordStop, .snapshot, .highlight],
        ]
        ForEach(0..<groups.count, id: \.self) { g in
            if g > 0 { Divider() }
            ForEach(groups[g], id: \.self) { kind in Button(L10n.t("macro.step.\(kind.rawValue)")) { pick(kind) } }
        }
    }

    private func addStep(_ kind: MacroStepKind) {
        var s = MacroStep(kind)
        if kind.needsInput { s.input = model.switcher.preview ?? model.inputs.first?.id }
        if kind.needsOverlay { s.overlay = 1 }
        if kind.needsChannel { s.channel = model.audioChannels.first?.id }
        if kind == .wait { s.seconds = 2 }
        if kind == .audioFade { s.seconds = 3; s.level = -90 }
        if kind == .runMacro { s.macro = 1 }
        macro.wrappedValue.steps.append(s)
    }

    private func step(_ k: Int) -> Binding<MacroStep> {
        Binding(get: { macro.wrappedValue.steps.indices.contains(k) ? macro.wrappedValue.steps[k] : MacroStep(.wait) },
                set: { if macro.wrappedValue.steps.indices.contains(k) { macro.wrappedValue.steps[k] = $0 } })
    }

    private func stepRow(_ k: Int) -> some View {
        let s = step(k)
        let v = s.wrappedValue
        return VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
            Text("\(k + 1).").monospacedDigit().frame(width: 22, alignment: .trailing).foregroundStyle(Theme.textDim)
            Menu { stepKindItems { kind in
                var n = s.wrappedValue
                n.kind = kind
                if kind.needsInput, n.input == nil { n.input = model.switcher.preview ?? model.inputs.first?.id }
                if kind.needsOverlay, n.overlay == nil { n.overlay = 1 }
                if kind.needsChannel, n.channel == nil { n.channel = model.audioChannels.first?.id }
                if kind == .wait, n.seconds == nil { n.seconds = 2 }
                if kind == .audioFade { n.seconds = n.seconds ?? 3; n.level = n.level ?? -90 }
                if kind == .runMacro, n.macro == nil { n.macro = 1 }
                s.wrappedValue = n
            } } label: { Text(L10n.t("macro.step.\(v.kind.rawValue)")) }
                .frame(width: 190)
            if v.kind.needsInput { inputPicker(s.input, allowAny: false) }
            if v.kind.needsOverlay {
                Picker("", selection: Binding(get: { v.overlay ?? 1 }, set: { s.wrappedValue.overlay = $0 })) {
                    ForEach(1...4, id: \.self) { n in Text("Overlay \(n)").tag(n) }
                }
                .labelsHidden().frame(width: 130)
            }
            if v.kind.needsChannel {
                Picker("", selection: Binding(get: { v.channel ?? "" }, set: { s.wrappedValue.channel = $0 })) {
                    if !model.audioChannels.contains(where: { $0.id == v.channel }) { Text(L10n.t("macro.choose")).tag(v.channel ?? "") }
                    ForEach(model.audioChannels) { c in Text(c.name).tag(c.id) }
                }
                .labelsHidden().frame(width: 200)
            }
            if v.kind == .wait {
                TextField("", value: Binding(get: { v.seconds ?? 0 }, set: { s.wrappedValue.seconds = min(max($0, 0), MacroStep.maxWait) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                Text("s")
            }
            if v.kind == .audioFade {
                Text(L10n.t("macro.fade_to")).foregroundStyle(Theme.textDim)
                TextField("", value: Binding(get: { v.level ?? 0 }, set: { s.wrappedValue.level = min(max($0, -90), 10) }),
                          format: .number.precision(.fractionLength(0...1)))
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                Text("dB")
                TextField("", value: Binding(get: { v.seconds ?? 0 }, set: { s.wrappedValue.seconds = min(max($0, 0), MacroStep.maxFade) }),
                          format: .number.precision(.fractionLength(0...2)))
                    .textFieldStyle(.roundedBorder).frame(width: 56)
                Text("s")
            }
            if v.kind == .runMacro {
                Picker("", selection: Binding(get: { v.macro ?? 1 }, set: { s.wrappedValue.macro = $0 })) {
                    ForEach(Array(model.macroBook.macros.prefix(MacroBook.maxNumber).enumerated()), id: \.offset) { n, m in
                        Text("\(n + 1)  \(m.name)").tag(n + 1)
                    }
                }
                .labelsHidden().frame(width: 200)
            }
            Menu {
                Button(L10n.t("macro.cond.none")) { s.wrappedValue.condition = nil }
                Divider()
                ForEach(MacroCondition.Kind.allCases, id: \.self) { c in
                    Button(L10n.t("macro.cond.\(c.rawValue)")) {
                        s.wrappedValue.condition = MacroCondition(c, input: c.needsInput ? (v.condition?.input ?? model.switcher.program ?? model.inputs.first?.id) : nil)
                    }
                }
            } label: { Image(systemName: v.condition == nil ? "questionmark.diamond" : "questionmark.diamond.fill") }
                .menuStyle(.borderlessButton).fixedSize().help(L10n.t("macro.cond.help"))
            if !v.isComplete { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(L10n.t("macro.incomplete")) }
            Spacer()
            Button { move(k, -1) } label: { Image(systemName: "chevron.up") }.buttonStyle(.borderless).disabled(k == 0)
            Button { move(k, 1) } label: { Image(systemName: "chevron.down") }.buttonStyle(.borderless)
                .disabled(k == macro.wrappedValue.steps.count - 1)
            Button { macro.wrappedValue.steps.remove(at: k) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
            if let c = v.condition {
                HStack(spacing: 8) {
                    Text(L10n.t("macro.cond.only_if")).foregroundStyle(Theme.textDim)
                    Text(L10n.t("macro.cond.\(c.kind.rawValue)"))
                    if c.kind.needsInput {
                        inputPicker(Binding(get: { s.wrappedValue.condition?.input }, set: { s.wrappedValue.condition?.input = $0 }), allowAny: false)
                    }
                }
                .font(.system(size: 11))
                .padding(.leading, 30)
            }
        }
    }

    private func move(_ k: Int, _ d: Int) {
        let j = k + d
        guard macro.wrappedValue.steps.indices.contains(j) else { return }
        macro.wrappedValue.steps.swapAt(k, j)
    }

    private func inputPicker(_ b: Binding<InputID?>, allowAny: Bool) -> some View {
        Picker("", selection: b) {
            if allowAny { Text(L10n.t("macro.any_input")).tag(InputID?.none) }
            else if b.wrappedValue == nil || !model.inputs.contains(where: { $0.id == b.wrappedValue }) {
                Text(L10n.t("macro.choose")).tag(b.wrappedValue)
            }
            ForEach(model.inputs) { i in Text("\(i.number)  \(i.name)").tag(InputID?.some(i.id)) }
        }
        .labelsHidden().frame(width: 200)
    }

    // MARK: Triggers

    private func triggerRow(_ k: Int) -> some View {
        let t = Binding<MacroTrigger>(
            get: { macro.wrappedValue.triggers.indices.contains(k) ? macro.wrappedValue.triggers[k] : MacroTrigger(.programIn) },
            set: { if macro.wrappedValue.triggers.indices.contains(k) { macro.wrappedValue.triggers[k] = $0 } })
        let v = t.wrappedValue
        return HStack(spacing: 8) {
            Toggle("", isOn: t.enabled).labelsHidden()
            Picker("", selection: t.event) {
                ForEach(MacroTriggerEvent.allCases, id: \.self) { e in Text(L10n.t("macro.event.\(e.rawValue)")).tag(e) }
            }
            .labelsHidden().frame(width: 220)
            if v.event.hasInput { inputPicker(t.input, allowAny: true) }
            if v.event == .timeOfDay {
                TextField("HH:mm", text: Binding(get: { v.time ?? "" }, set: { t.wrappedValue.time = $0 }))
                    .textFieldStyle(.roundedBorder).frame(width: 70)
                if MacroTrigger.normalizedTime(v.time) == nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(L10n.t("macro.time_invalid"))
                }
            }
            Spacer()
            Button { macro.wrappedValue.triggers.remove(at: k) } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
        }
    }
}
#endif
