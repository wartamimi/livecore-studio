#if os(macOS)
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// Visual scene editor for one input: its layers (PiP, side-by-side, logos, titles...) drawn on a
/// 16:9 canvas from the live thumbnails. Drag a layer to move it, drag a corner to resize it
/// (aspect locked by default). Every change is applied immediately; the input is put on Preview
/// so the exact GPU composition is visible there while editing.
struct SceneEditorSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let input: InputID
    @State private var layers: [Layer] = []
    @State private var selected = 0
    @State private var lockAspect = true
    @State private var dragStart: NormRect?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("\(L10n.t("scene.title")) — \(name(input))").font(.headline)
            HStack(alignment: .top, spacing: 12) {
                canvas.frame(width: 576, height: 324)
                inspector.frame(width: 280)
            }
            Text(L10n.t("scene.hint")).font(.system(size: 11)).foregroundStyle(Theme.textDim)
            HStack {
                Spacer()
                Button(L10n.t("common.ok")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .onAppear {
            layers = model.layers(of: input)
            selected = layers.count > 1 ? layers.count - 1 : 0
            model.preview(input)
        }
    }

    // MARK: Canvas

    private var canvas: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color.black)
                ForEach(Array(layers.enumerated()), id: \.offset) { i, layer in
                    layerView(i, layer, canvas: size)
                }
                // Title-safe guides (5 %).
                Rectangle().stroke(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .frame(width: size.width * 0.9, height: size.height * 0.9)
                    .offset(x: size.width * 0.05, y: size.height * 0.05)
                    .allowsHitTesting(false)
            }
            .clipped()
        }
        .overlay(Rectangle().stroke(Theme.border))
    }

    private func layerView(_ i: Int, _ layer: Layer, canvas: CGSize) -> some View {
        let r = layer.rect
        let frame = CGRect(x: r.x * canvas.width, y: r.y * canvas.height, width: r.width * canvas.width, height: r.height * canvas.height)
        let isSel = i == selected
        return ZStack(alignment: .topLeading) {
            PixelBufferView(feed: model.feed(for: layer.source))
                .opacity(layer.opacity)
                .frame(width: frame.width, height: frame.height)
                .overlay(Rectangle().stroke(isSel ? Theme.accent : Color.white.opacity(0.35), lineWidth: isSel ? 2 : 1))
                .overlay(alignment: .topLeading) {
                    Text("\(i + 1) \(name(layer.source))").font(.system(size: 9, weight: .bold))
                        .padding(2).background(Color.black.opacity(0.6))
                }
                .contentShape(Rectangle())
                .onTapGesture { selected = i }
                .gesture(DragGesture(minimumDistance: 1)
                    .onChanged { g in
                        selected = i
                        let start = dragStart ?? layers[i].rect
                        dragStart = start
                        var m = LayerEditing.move(start, dx: g.translation.width / canvas.width, dy: g.translation.height / canvas.height)
                        m.x = LayerEditing.snap(m.x); m.y = LayerEditing.snap(m.y)
                        update(i) { $0.rect = m }
                    }
                    .onEnded { _ in dragStart = nil })
            if isSel {
                ForEach(LayerEditing.Handle.allCases, id: \.self) { h in
                    handle(h, index: i, frame: frame, canvas: canvas)
                }
            }
        }
        .offset(x: frame.minX, y: frame.minY)
    }

    private func handle(_ h: LayerEditing.Handle, index i: Int, frame: CGRect, canvas: CGSize) -> some View {
        let x: CGFloat = (h == .topLeft || h == .bottomLeft) ? 0 : frame.width
        let y: CGFloat = (h == .topLeft || h == .topRight) ? 0 : frame.height
        return Rectangle().fill(Theme.accent).frame(width: 10, height: 10)
            .offset(x: x - 5, y: y - 5)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    let start = dragStart ?? layers[i].rect
                    dragStart = start
                    let aspect = lockAspect ? start.width / max(start.height, 0.0001) : nil
                    let r = LayerEditing.resize(start, handle: h, dx: g.translation.width / canvas.width,
                                                dy: g.translation.height / canvas.height, aspect: aspect)
                    update(i) { $0.rect = r }
                }
                .onEnded { _ in dragStart = nil })
    }

    // MARK: Inspector

    private var inspector: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.t("scene.layers")).font(.system(size: 11, weight: .bold))
                Spacer()
                Menu {
                    ForEach(model.inputs.filter { $0.id != input }) { info in
                        Button("\(info.number) \(info.name)") { addLayer(info.id) }
                    }
                } label: { Image(systemName: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
            }
            List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {
                ForEach(Array(layers.enumerated()).reversed(), id: \.offset) { i, l in
                    Text("\(i + 1)  \(name(l.source))\(i == 0 ? " (\(L10n.t("scene.base")))" : "")").tag(i)
                }
            }
            .frame(height: 110)
            HStack {
                Button { move(by: 1) } label: { Image(systemName: "arrow.up") }.disabled(selected == 0 || selected >= layers.count - 1)
                Button { move(by: -1) } label: { Image(systemName: "arrow.down") }.disabled(selected <= 1)
                Spacer()
                Button(role: .destructive) { removeSelected() } label: { Image(systemName: "trash") }.disabled(selected == 0)
            }
            if layers.indices.contains(selected) {
                let l = layers[selected]
                Picker(L10n.t("scene.preset"), selection: Binding(get: { LayoutPreset?.none }, set: { p in
                    if let p { update(selected) { $0.rect = p.rect } } })) {
                    Text("—").tag(LayoutPreset?.none)
                    ForEach(LayoutPreset.allCases, id: \.self) { p in Text(p.rawValue).tag(Optional(p)) }
                }
                Picker(L10n.t("scene.scale"), selection: Binding(get: { l.scaleMode }, set: { m in update(selected) { $0.scaleMode = m } })) {
                    ForEach(ScaleMode.allCases, id: \.self) { m in Text(m.rawValue).tag(m) }
                }
                HStack {
                    Text(L10n.t("scene.opacity")).font(.system(size: 11))
                    Slider(value: Binding(get: { l.opacity }, set: { v in update(selected) { $0.opacity = v } }), in: 0...1)
                }
                Toggle(L10n.t("scene.lock"), isOn: $lockAspect).font(.system(size: 11))
                Button(L10n.t("scene.fit_source")) { fitToSource(selected) }.font(.system(size: 11))
                Text(String(format: "x %.2f  y %.2f  w %.2f  h %.2f", l.rect.x, l.rect.y, l.rect.width, l.rect.height))
                    .font(.system(size: 10).monospacedDigit()).foregroundStyle(Theme.textDim)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Edits

    private func update(_ i: Int, _ change: (inout Layer) -> Void) {
        guard layers.indices.contains(i) else { return }
        change(&layers[i])
        model.setLayers(layers, of: input)
    }

    private func addLayer(_ source: InputID) {
        layers.append(Layer(source: source, rect: LayoutPreset.pipTopRight.rect, scaleMode: .fill))
        selected = layers.count - 1
        model.setLayers(layers, of: input)
    }

    private func removeSelected() {
        guard selected > 0, selected < layers.count else { return }
        layers.remove(at: selected)
        selected = min(selected, layers.count - 1)
        model.setLayers(layers, of: input)
    }

    private func move(by delta: Int) {
        let to = selected + delta
        let new = LayerEditing.reorder(layers, from: selected, to: to)
        guard new.map(\.source) != layers.map(\.source) || new.map(\.rect) != layers.map(\.rect) else { return }
        layers = new
        selected = to
        model.setLayers(layers, of: input)
    }

    /// Resizes the layer box to the source's own aspect ratio (no bars, no crop), keeping its width.
    private func fitToSource(_ i: Int) {
        guard layers.indices.contains(i), let src = model.frameSize(layers[i].source),
              let aspect = LayerEditing.normalizedAspect(source: src, canvas: model.settings.output.size) else { return }
        update(i) { l in l.rect.height = max(l.rect.width / aspect, LayerEditing.minimumSize) }
    }

    private func name(_ id: InputID) -> String { model.inputs.first { $0.id == id }?.name ?? "?" }
}
#endif
