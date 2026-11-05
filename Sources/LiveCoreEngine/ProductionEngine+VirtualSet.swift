#if os(macOS)
import Foundation
import LiveCoreCore

/// Virtual Set inputs (0.59.0): studio picture + screen input + keyed talents as layers.
extension ProductionEngine {
    @discardableResult
    public func addVirtualSet(_ design: VirtualSetDesign, id: InputID? = nil) -> InputID {
        let src = VirtualSetSource(id: id ?? InputID(UUID().uuidString), design: design, outputSize: settings.output.size)
        add(src)
        applyVirtualSetLayers(src.id)
        return src.id
    }

    public func updateVirtualSet(_ id: InputID, _ design: VirtualSetDesign) {
        guard let v = source(id) as? VirtualSetSource else { return }
        let previous = v.design
        v.update(design)
        applyVirtualSetLayers(id, previous: previous)
        publishInputs()
    }

    /// Rebuilds the layers from the design: screen input in the studio screen, then the talents
    /// at their spots (cut at the desk). Talents without a key get the default green key when
    /// `autoKey` is on. Layers the operator added after the talents are kept on top.
    func applyVirtualSetLayers(_ id: InputID, previous: VirtualSetDesign? = nil) {
        guard let v = source(id) as? VirtualSetSource else { return }
        let d = v.design, p = v.placement
        control.mutate { st in
            let sources = st.sources
            let usable: (String?) -> InputID? = { raw in
                guard let raw else { return nil }
                let i = InputID(raw)
                return i != id && sources[i] != nil && !(sources[i] is VirtualSetSource) ? i : nil
            }
            var ids = [d.screenInput] + d.talents.map { Optional($0) }
            if let previous { ids += [previous.screenInput] + previous.talents.map { Optional($0) } }
            let managed = Set(ids.compactMap { $0.map { InputID($0) } })
            let old = st.layers[id] ?? []
            var layers = [old.first ?? Layer(source: id)]
            if let s = usable(d.screenInput), let r = p.screen {
                layers.append(Layer(source: s, rect: r, scaleMode: .fill, locked: true))
            }
            for (i, raw) in d.talents.enumerated() where i < p.talents.count {
                guard let t = usable(raw) else { continue }
                let spot = p.talents[i]
                let style = spot.cropBottom > 0 ? LayerStyle(crop: LayerStyle.Crop(bottom: spot.cropBottom)) : nil
                layers.append(Layer(source: t, rect: spot.rect, scaleMode: .fill, style: style, locked: true))
                if d.autoKey, !(st.keys[t]?.enabled ?? false) {
                    var k = st.keys[t] ?? ChromaKey()
                    k.enabled = true
                    st.keys[t] = k.clamped
                }
            }
            // Extra layers the operator added (logos, lower thirds…) stay above the set.
            layers += old.dropFirst().filter { !managed.contains($0.source) && $0.source != id }
            st.drafts[id] = nil
            st.layers[id] = st.sanitized(layers, of: id)
        }
    }
}
#endif
