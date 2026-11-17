#if os(macOS)
import SwiftUI

/// "Soft Pro" slider (0.80.0), used for every slider and seek bar: a thin rounded track filled in
/// the accent colour and a round white knob with a soft accent halo that grows while dragged.
/// Same arguments as SwiftUI's `Slider`; VoiceOver still sees a standard slider.
struct SoftSlider<V: BinaryFloatingPoint>: View where V.Stride: BinaryFloatingPoint {
    @Binding var value: V
    let range: ClosedRange<V>
    var step: V.Stride?
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(value: Binding<V>, in range: ClosedRange<V> = 0...1, step: V.Stride? = nil,
         onEditingChanged: @escaping (Bool) -> Void = { _ in }) {
        _value = value; self.range = range; self.step = step; self.onEditingChanged = onEditingChanged
    }

    private static var knob: CGFloat { 14 }

    private var fraction: CGFloat {
        let span = range.upperBound - range.lowerBound
        return span > 0 ? CGFloat(min(max((value - range.lowerBound) / span, 0), 1)) : 0
    }

    var body: some View {
        GeometryReader { g in
            let travel = max(g.size.width - Self.knob, 1), x = fraction * travel
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 4)
                Capsule().fill(enabled ? Theme.accent : Theme.textDim).frame(width: x + Self.knob / 2, height: 4)
                Circle().fill(Theme.accent.opacity(dragging ? 0.30 : hovering ? 0.22 : 0.14))
                    .frame(width: Self.knob + 8, height: Self.knob + 8)
                    .overlay(Circle().fill(Color.white).frame(width: Self.knob, height: Self.knob)
                        .shadow(color: .black.opacity(0.5), radius: 1.5, y: 1))
                    .scaleEffect(dragging ? 1.12 : 1)
                    .offset(x: x - 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { d in
                    if !dragging { dragging = true; onEditingChanged(true) }
                    set(CGFloat(d.location.x - Self.knob / 2) / travel)
                }
                .onEnded { _ in dragging = false; onEditingChanged(false) })
        }
        .frame(height: 22)
        .frame(minWidth: 60)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(Theme.motion, value: dragging)
        .accessibilityRepresentation { Slider(value: $value, in: range) }
    }

    private func set(_ f: CGFloat) {
        var v = range.lowerBound + V(min(max(f, 0), 1)) * (range.upperBound - range.lowerBound)
        if let step, step > 0 {
            v = range.lowerBound + V(((v - range.lowerBound) / V(step)).rounded()) * V(step)
            v = min(max(v, range.lowerBound), range.upperBound)
        }
        if v != value {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { value = v }
        }
    }
}
#endif
