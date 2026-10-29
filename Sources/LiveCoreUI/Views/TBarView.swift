#if os(macOS)
import SwiftUI
import LiveCoreCore

/// Broadcast-style manual T-bar, horizontal: a lever in a recessed track with tick marks and
/// only the percentage shown. Position 0 is the left end, 1 the right; the bar rests at either
/// end (flip-flop) and the lit part of the track shows how far the transition has gone.
struct TBarControl: View {
    @EnvironmentObject var model: AppModel

    private let trackHeight: CGFloat = 26
    private let handleWidth: CGFloat = 18
    private static let space = "tbar"
    /// Where on the handle the drag started, so grabbing it never makes it jump.
    @State private var grab: CGFloat?

    private var rest: Double { model.switcher.tbarRest }
    private var progress: Double { abs(model.tbar - rest) }
    private var auto: Bool { model.switcher.transition.map { $0.manualPosition == nil } ?? false }
    private var lit: Bool { progress > 0.001 || auto }

    var body: some View {
        VStack(spacing: 3) {
            lever
            Text("\(Int((progress * 100).rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(lit ? Theme.accent : Theme.textDim)
        }
        .help(L10n.t("tbar.help"))
    }

    private var lever: some View {
        GeometryReader { g in
            let range = max(g.size.width - handleWidth, 1)
            let x = model.tbar * range                       // left edge of the handle
            let handleMid = x + handleWidth / 2
            let restX = rest * range + handleWidth / 2
            ZStack(alignment: .leading) {
                // Recessed track
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color.black.opacity(0.65), Color(white: 0.11)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.10), lineWidth: 1))
                // Tick marks (every 10 %, longer at 0 / 50 / 100), above and below the slot
                ForEach(0...10, id: \.self) { i in
                    let major = i % 5 == 0
                    VStack { tick(major); Spacer(); tick(major) }
                        .frame(height: trackHeight - 4)
                        .offset(x: handleWidth / 2 + CGFloat(i) / 10 * range - 0.5)
                }
                // Slot + lit progress from the rest end to the handle
                Capsule().fill(Color.black.opacity(0.8)).frame(height: 4)
                    .padding(.horizontal, handleWidth / 2)
                Capsule().fill(Theme.accent)
                    .frame(width: max(0, abs(handleMid - restX)), height: 4)
                    .offset(x: min(handleMid, restX))
                    .shadow(color: Theme.accent.opacity(0.8), radius: 4)
                    .opacity(progress > 0.001 ? 1 : 0)
                handle.offset(x: x)
            }
            .frame(height: trackHeight)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { v in
                        if grab == nil {
                            let off = v.startLocation.x - x
                            grab = (0...handleWidth).contains(off) ? off : handleWidth / 2
                        }
                        let left = v.location.x - (grab ?? handleWidth / 2)
                        let p = Double(min(max(left / range, 0), 1))
                        if abs(p - model.tbar) > 0.0005 { model.setTBar(p) }
                    }
                    .onEnded { _ in grab = nil }
            )
        }
        .frame(height: trackHeight + 10)
    }

    private func tick(_ major: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(major ? 0.45 : 0.2)).frame(width: 1, height: major ? 5 : 3)
    }

    /// Metallic lever cap with grip lines.
    private var handle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62), Color(white: 0.78)],
                                     startPoint: .leading, endPoint: .trailing))
            RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.55), lineWidth: 1)
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(Color.black.opacity(0.35)).frame(width: 1)
                        .overlay(Rectangle().fill(Color.white.opacity(0.6)).frame(width: 1).offset(x: 1))
                }
            }
            .padding(.vertical, 8)
            Rectangle().fill(lit ? Theme.accent : Theme.program.opacity(0.85))
                .frame(width: 2).padding(.vertical, 3).offset(x: handleWidth / 2 - 4)
        }
        .frame(width: handleWidth, height: trackHeight + 10)
        .shadow(color: .black.opacity(0.6), radius: 3, x: 1, y: 2)
    }
}
#endif
