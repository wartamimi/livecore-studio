#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// vMix-style Layer Designer on the Preview monitor: the layers of the input on Preview are edited
/// right on the picture. Drag to move, handles to resize (snapping to the canvas, the centre and
/// the other layers), Crop mode to cut edges (Shift = both sides), plus border, rounded corners,
/// hide/show, lock, flatten and saved layouts. The Preview picture underneath is the real GPU result.
/// Edits are a draft shown on Preview only; Program gets them when the input is taken to Program
/// with a transition (CUT, AUTO, T-bar).
final class LayerDesignerState: ObservableObject {
    enum Mode: String { case position, crop }

    @Published var active = false
    @Published var mode: Mode = .position
    @Published var snapping = true
    @Published private(set) var input: InputID?
    @Published private(set) var layers: [Layer] = []
    @Published var selected = 0
    /// Snap lines shown while dragging (normalized).
    @Published var guidesX: [Double] = []
    @Published var guidesY: [Double] = []
    var dragStart: (rect: NormRect, crop: LayerStyle.Crop)? {
        didSet { if dragStart != nil && oldValue == nil { history?.breakCoalescing() } }
    }
    /// Undo / redo of this input's layers (⌘Z / ⇧⌘Z while the designer is open). One drag is one step.
    @Published private(set) var history: EditHistory<[Layer]>?

    /// Re-reads the layers of the input on Preview (when it changes or the designer opens).
    func load(_ model: AppModel, input id: InputID?) {
        input = id
        layers = id.flatMap { model.draftLayers(of: $0) } ?? id.map { model.layers(of: $0) } ?? []
        if !layers.indices.contains(selected) || selected == 0 { selected = max(layers.count - 1, 0) }
        history = id == nil ? nil : EditHistory(layers)
        model.editorUndo = EditorUndo(canUndo: { [weak self] in self?.history?.canUndo ?? false },
                                      canRedo: { [weak self] in self?.history?.canRedo ?? false },
                                      undo: { [weak self, weak model] in if let model { self?.undo(model) } },
                                      redo: { [weak self, weak model] in if let model { self?.redo(model) } })
    }

    func update(_ model: AppModel, _ i: Int, _ change: (inout Layer) -> Void) {
        guard let input, layers.indices.contains(i) else { return }
        change(&layers[i])
        model.setDraftLayers(layers, of: input)
        record()
    }

    func replaceAll(_ model: AppModel, _ new: [Layer]) {
        guard let input else { return }
        model.setDraftLayers(new, of: input)
        layers = model.draftLayers(of: input) ?? new
        if !layers.indices.contains(selected) { selected = max(layers.count - 1, 0) }
        history?.breakCoalescing()
        record()
    }

    private func record() { history?.record(layers, now: ProcessInfo.processInfo.systemUptime) }

    func undo(_ model: AppModel) { if let v = history?.undo() { restore(model, v) } }
    func redo(_ model: AppModel) { if let v = history?.redo() { restore(model, v) } }

    private func restore(_ model: AppModel, _ v: [Layer]) {
        guard let input else { return }
        model.setDraftLayers(v, of: input)
        layers = model.draftLayers(of: input) ?? v
        if !layers.indices.contains(selected) { selected = max(layers.count - 1, 0) }
    }

    /// Hides the tools; the edits stay on Preview until the next transition.
    func close() { active = false }

    var selectedLayer: Layer? { layers.indices.contains(selected) ? layers[selected] : nil }

    /// Scenes have an empty canvas as layer 0; it is not drawn or edited.
    func editable(_ i: Int, model: AppModel) -> Bool {
        guard let input, i > 0 || model.inputs.first(where: { $0.id == input })?.kind != .scene else { return false }
        return true
    }
}

// MARK: - Canvas over the Preview picture

struct LayerDesignerCanvas: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: LayerDesignerState

    var body: some View {
        GeometryReader { geo in
            let canvas = fitted(geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear.contentShape(Rectangle()).onTapGesture { }   // keeps clicks off the monitor below
                ForEach(Array(state.layers.enumerated()), id: \.offset) { i, l in
                    if state.editable(i, model: model) { box(i, l, canvas) }
                }
                ForEach(state.guidesX, id: \.self) { x in
                    Rectangle().fill(Theme.accent).frame(width: 1, height: canvas.height)
                        .offset(x: canvas.minX + x * canvas.width, y: canvas.minY)
                }
                ForEach(state.guidesY, id: \.self) { y in
                    Rectangle().fill(Theme.accent).frame(width: canvas.width, height: 1)
                        .offset(x: canvas.minX, y: canvas.minY + y * canvas.height)
                }
            }
            // Drags are measured in this fixed space: a box that moves under the mouse would
            // otherwise feed its own movement back into the drag and jitter.
            .coordinateSpace(name: Self.space)
        }
    }

    static let space = "layer-designer"

    /// The picture's rectangle inside the monitor (output aspect, centred).
    private func fitted(_ size: CGSize) -> CGRect {
        let aspect = max(model.settings.output.size.aspect, 0.1)
        var w = size.width, h = w / aspect
        if h > size.height { h = size.height; w = h * aspect }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func frame(_ r: NormRect, _ c: CGRect) -> CGRect {
        CGRect(x: c.minX + r.x * c.width, y: c.minY + r.y * c.height, width: r.width * c.width, height: r.height * c.height)
    }

    private func box(_ i: Int, _ l: Layer, _ canvas: CGRect) -> some View {
        let f = frame(l.rect, canvas)
        let sel = i == state.selected
        let color: Color = l.isHidden ? Color.gray : (sel ? (state.mode == .crop ? Theme.warning : Theme.accent) : Color.white.opacity(0.55))
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color, style: StrokeStyle(lineWidth: sel ? 2 : 1, dash: l.isHidden ? [4, 3] : []))
                .background(Color.white.opacity(sel ? 0.04 : 0.001))
                .frame(width: max(f.width, 4), height: max(f.height, 4))
                .overlay(alignment: .topLeading) {
                    HStack(spacing: 3) {
                        Text("\(i + 1) \(name(l.source))").lineLimit(1)
                        if l.isLocked { Image(systemName: "lock.fill") }
                        if l.isHidden { Image(systemName: "eye.slash") }
                    }
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Color.black.opacity(0.65))
                }
                .contentShape(Rectangle())
                .onTapGesture { state.selected = i }
                .gesture(moveGesture(i, canvas))
            if sel && !l.isLocked && !l.isHidden {
                ForEach(LayerEditing.Handle.allCases, id: \.self) { h in handle(h, i, f, canvas) }
            }
        }
        .offset(x: f.minX, y: f.minY)
    }

    private func moveGesture(_ i: Int, _ canvas: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { g in
                state.selected = i
                guard state.layers.indices.contains(i), !state.layers[i].isLocked, !state.layers[i].isHidden else { return }
                if state.dragStart == nil { state.dragStart = (state.layers[i].rect, state.layers[i].style?.crop ?? .none) }
                guard let start = state.dragStart else { return }
                var r = LayerEditing.move(start.rect, dx: g.translation.width / canvas.width, dy: g.translation.height / canvas.height)
                if state.snapping && !NSEvent.modifierFlags.contains(.command) {
                    let s = LayerEditing.snapMove(r, others: others(i))
                    r = s.rect; state.guidesX = s.guidesX; state.guidesY = s.guidesY
                } else { state.guidesX = []; state.guidesY = [] }
                state.update(model, i) { $0.rect = r }
            }
            .onEnded { _ in endDrag() }
    }

    private func handle(_ h: LayerEditing.Handle, _ i: Int, _ f: CGRect, _ canvas: CGRect) -> some View {
        let a = h.anchor
        let crop = state.mode == .crop
        return Group {
            if crop {
                // Crop handles: bars on the edges, L-shapes at the corners.
                Rectangle().fill(Theme.warning)
                    .frame(width: h.isCorner ? 10 : (a.x == 0.5 ? 18 : 5), height: h.isCorner ? 10 : (a.y == 0.5 ? 18 : 5))
            } else {
                Rectangle().fill(Theme.accent).frame(width: 9, height: 9)
                    .overlay(Rectangle().stroke(Color.black.opacity(0.6), lineWidth: 1))
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Rectangle())
        .offset(x: a.x * f.width - 9, y: a.y * f.height - 9)
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { g in
                guard state.layers.indices.contains(i) else { return }
                if state.dragStart == nil { state.dragStart = (state.layers[i].rect, state.layers[i].style?.crop ?? .none) }
                guard let start = state.dragStart else { return }
                let dx = g.translation.width / canvas.width, dy = g.translation.height / canvas.height
                let shift = NSEvent.modifierFlags.contains(.shift)
                if crop {
                    let c = LayerEditing.crop(start.rect, crop: start.crop, handle: h, dx: dx, dy: dy, symmetric: shift)
                    state.update(model, i) { l in
                        var s = l.style ?? LayerStyle()
                        s.crop = c.crop
                        l.style = s.clamped
                        l.rect = c.rect
                    }
                } else {
                    // Corners keep the shape unless Shift is held; edges stretch one side.
                    let aspect = shift ? nil : start.rect.width / max(start.rect.height, 0.0001)
                    var r = LayerEditing.resize(start.rect, handle: h, dx: dx, dy: dy, aspect: aspect)
                    if state.snapping && !NSEvent.modifierFlags.contains(.command) && (!h.isCorner || shift) {
                        let s = LayerEditing.snapResize(r, handle: h, others: others(i))
                        r = s.rect; state.guidesX = s.guidesX; state.guidesY = s.guidesY
                    }
                    state.update(model, i) { $0.rect = r }
                }
            }
            .onEnded { _ in endDrag() })
        .help(crop ? L10n.t("designer.crop_help") : L10n.t("designer.resize_help"))
    }

    private func others(_ i: Int) -> [NormRect] {
        state.layers.enumerated().filter { $0.offset != i && !$0.element.isHidden && state.editable($0.offset, model: model) }.map(\.element.rect)
    }

    private func endDrag() {
        state.dragStart = nil
        state.guidesX = []; state.guidesY = []
    }

    private func name(_ id: InputID) -> String { model.inputs.first { $0.id == id }?.name ?? "?" }
}

// MARK: - Tool bar under the Preview picture

struct LayerDesignerBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: LayerDesignerState
    @State private var showStyle = false

    var body: some View {
        HStack(spacing: 6) {
            layerMenu
            if let l = state.selectedLayer {
                iconToggle(l.isHidden ? "eye.slash.fill" : "eye.fill", on: !l.isHidden, help: L10n.t("designer.visible")) {
                    state.update(model, state.selected) { $0.hidden = $0.isHidden ? nil : true }
                }
                iconToggle(l.isLocked ? "lock.fill" : "lock.open", on: l.isLocked, help: L10n.t("designer.lock")) {
                    state.update(model, state.selected) { $0.locked = $0.isLocked ? nil : true }
                }
            }
            Picker("", selection: $state.mode) {
                Image(systemName: "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left").tag(LayerDesignerState.Mode.position)
                    .help(L10n.t("designer.mode_position"))
                Image(systemName: "crop").tag(LayerDesignerState.Mode.crop).help(L10n.t("designer.mode_crop"))
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 76)
            .help(L10n.t("designer.mode_help"))
            iconToggle("squareshape.split.3x3", on: state.snapping, help: L10n.t("designer.snap")) { state.snapping.toggle() }
            Button { showStyle.toggle() } label: { Image(systemName: "square.dashed.inset.filled") }
                .buttonStyle(.borderless)
                .help(L10n.t("designer.style"))
                .disabled(state.selectedLayer == nil)
                .popover(isPresented: $showStyle, arrowEdge: .bottom) {
                    LayerStylePopover(state: state).environmentObject(model).padding(12).frame(width: 280)
                }
            iconToggle("square.3.layers.3d.down.right", on: state.layers.first?.flatten == true,
                       help: L10n.t("designer.flatten")) {
                state.update(model, 0) { $0.flatten = $0.flatten == true ? nil : true }
            }
            .disabled(state.layers.count < 2)
            templateMenu
            Button { state.undo(model) } label: { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.borderless).help(L10n.t("undo.undo") + " (⌘Z)")
                .disabled(state.history?.canUndo != true)
            Button { state.redo(model) } label: { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.borderless).help(L10n.t("undo.redo") + " (⇧⌘Z)")
                .disabled(state.history?.canRedo != true)
            Spacer(minLength: 0)
            Button { state.close() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless).help(L10n.t("designer.close"))
        }
        .font(.system(size: 11))
        .padding(.horizontal, 4).padding(.top, 3)
    }

    private func iconToggle(_ icon: String, on: Bool, help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 22, height: 18)
                .background(on ? Theme.accent.opacity(0.45) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.borderless)
        .help(help)
    }

    private var layerMenu: some View {
        Menu {
            ForEach(Array(state.layers.enumerated()).reversed(), id: \.offset) { i, l in
                if state.editable(i, model: model) {
                    Button((i == state.selected ? "✓ " : "") + "\(i + 1)  \(name(l.source))"
                           + (l.isHidden ? "  (" + L10n.t("designer.hidden") + ")" : "")
                           + (l.isLocked ? "  🔒" : "")) { state.selected = i }
                }
            }
            Divider()
            Menu(L10n.t("scene.add_layer")) {
                ForEach(model.inputs.filter { $0.id != state.input }) { info in
                    Button("\(info.number) \(info.name)") { addLayer(info.id) }
                }
            }
            if state.selected > 0 {
                Button(L10n.t("designer.remove_layer"), role: .destructive) { removeSelected() }
            }
        } label: {
            Text(state.selectedLayer.map { "\(state.selected + 1) \(name($0.source))" } ?? L10n.t("designer.no_layer"))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: 140, alignment: .leading)
        .help(L10n.t("designer.layers_help"))
    }

    private var templateMenu: some View {
        Menu {
            Button(L10n.t("designer.template_save")) { saveTemplate() }.disabled(state.input == nil)
            if !model.layoutTemplates.isEmpty {
                Divider()
                ForEach(model.layoutTemplates) { t in
                    Button(L10n.f("designer.template_apply", t.name)) { applyTemplate(t) }
                }
                Divider()
                Menu(L10n.t("designer.template_delete")) {
                    ForEach(model.layoutTemplates) { t in Button(t.name, role: .destructive) { model.deleteLayoutTemplate(t) } }
                }
            }
        } label: { Image(systemName: "rectangle.3.group") }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(L10n.t("designer.templates"))
    }

    private func addLayer(_ source: InputID) {
        var l = state.layers
        l.append(Layer(source: source, rect: LayoutPreset.pipTopRight.rect, scaleMode: .fill))
        state.replaceAll(model, l)
        state.selected = state.layers.count - 1
    }

    private func removeSelected() {
        guard state.selected > 0, state.selected < state.layers.count else { return }
        var l = state.layers
        l.remove(at: state.selected)
        state.selected = l.count - 1
        state.replaceAll(model, l)
    }

    private func saveTemplate() {
        guard let input = state.input else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("designer.template_save")
        alert.informativeText = L10n.t("designer.template_name")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = model.inputs.first { $0.id == input }?.name ?? "Layout"
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.t("common.ok"))
        alert.addButton(withTitle: L10n.t("settings.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        model.saveLayoutTemplate(name: name.isEmpty ? "Layout" : name, layers: state.layers)
    }

    private func applyTemplate(_ t: LayoutTemplate) {
        guard let input = state.input else { return }
        let existing = Set(model.inputs.map(\.id))
        state.replaceAll(model, t.apply(to: state.layers) { $0 != input && existing.contains($0) })
    }

    private func name(_ id: InputID) -> String { model.inputs.first { $0.id == id }?.name ?? "?" }
}

/// Border, corners, shape and crop numbers of the selected layer.
private struct LayerStylePopover: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var state: LayerDesignerState

    var body: some View {
        let st = state.selectedLayer?.style ?? LayerStyle()
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.t("designer.style"))
            Picker(L10n.t("scene.shape"), selection: binding(\.shape)) {
                Text(L10n.t("scene.shape.rectangle")).tag(LayerStyle.Shape.rectangle)
                Text(L10n.t("scene.shape.ellipse")).tag(LayerStyle.Shape.ellipse)
            }
            if st.shape == .rectangle { slider(L10n.t("scene.corner"), binding(\.cornerRadius), 0...0.5) }
            slider(L10n.t("scene.border"), binding(\.borderWidth), 0...0.03)
            ColorPicker(L10n.t("scene.border_color"), selection: Binding(
                get: { Color(red: st.borderColor.r, green: st.borderColor.g, blue: st.borderColor.b) },
                set: { c in
                    let ns = NSColor(c).usingColorSpace(.sRGB) ?? .white
                    updateStyle { $0.borderColor = ChromaKey.RGB(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent)) }
                }), supportsOpacity: false)
            if let l = state.selectedLayer {
                HStack {
                    Text(L10n.t("scene.opacity"))
                    Slider(value: Binding(get: { l.opacity }, set: { v in state.update(model, state.selected) { $0.opacity = v } }), in: 0...1)
                }
            }
            Text(String(format: L10n.t("designer.crop_values"), st.crop.left * 100, st.crop.top * 100, st.crop.right * 100, st.crop.bottom * 100))
                .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
            HStack {
                Button(L10n.t("designer.crop_reset")) { resetCrop() }.disabled(st.crop.isNone)
                Button(L10n.t("scene.style_reset")) { state.update(model, state.selected) { $0.style = nil } }
                    .disabled(state.selectedLayer?.style == nil)
            }
        }
        .font(.system(size: 11))
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>) -> some View {
        HStack(spacing: 4) {
            Text(title).frame(width: 70, alignment: .leading)
            Slider(value: value, in: range)
            Text("\(Int((value.wrappedValue * 100).rounded()))%").font(.system(size: 10).monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }

    private func binding<T>(_ path: WritableKeyPath<LayerStyle, T>) -> Binding<T> {
        Binding(get: { (state.selectedLayer?.style ?? LayerStyle())[keyPath: path] },
                set: { v in updateStyle { $0[keyPath: path] = v } })
    }

    private func updateStyle(_ change: (inout LayerStyle) -> Void) {
        state.update(model, state.selected) { l in
            var s = l.style ?? LayerStyle()
            change(&s)
            l.style = s.clamped
        }
    }

    /// Uncrops in place: the picture grows back out to its full size around where it is.
    private func resetCrop() {
        guard let l = state.selectedLayer, let c = l.style?.crop else { return }
        let fullW = l.rect.width / max(1 - c.left - c.right, 0.1), fullH = l.rect.height / max(1 - c.top - c.bottom, 0.1)
        state.update(model, state.selected) { l in
            l.rect = NormRect(x: l.rect.x - c.left * fullW, y: l.rect.y - c.top * fullH, width: fullW, height: fullH)
            var s = l.style ?? LayerStyle()
            s.crop = .none
            l.style = s
        }
    }
}
#endif
