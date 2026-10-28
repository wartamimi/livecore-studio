#if os(macOS)
import SwiftUI
import LiveCoreCore

/// Broadcast-style manual T-bar: a vertical lever in a recessed track with tick marks.
/// Position 0 is the bottom, 1 the top; the bar rests at either end (flip-flop) and the lit
/// part of the track shows how far the transition has gone from the rest end.
struct TBarControl: View {
    @EnvironmentObject var model: AppModel
    var height: CGFloat = 150

    private let trackWidth: CGFloat = 34
    private let handleHeight: CGFloat = 26
    private static let space = "tbar"
    /// Where on the handle the drag started, so grabbing it never makes it jump.
    @State private var grab: CGFloat?

    private var rest: Double { model.switcher.tbarRest }
    private var progress: Double { abs(model.tbar - rest) }
    private var auto: Bool { model.switcher.transition.map { $0.manualPosition == nil } ?? false }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            lever
            VStack(alignment: .leading, spacing: 4) {
                Text("T-BAR").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.textDim)
                Text(auto ? "AUTO" : "\(Int((progress * 100).rounded()))%")
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(progress > 0.001 || auto ? Theme.accent : Theme.text)
                Text(L10n.t("tbar.help")).font(.system(size: 9)).foregroundStyle(Theme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .help(L10n.t("tbar.help"))
    }

    private var lever: some View {
        GeometryReader { g in
            let range = g.size.height - handleHeight
            let y = (1 - model.tbar) * range           // top of the handle
            let restY = (1 - rest) * range + handleHeight / 2
            let handleMid = y + handleHeight / 2
            ZStack(alignment: .top) {
                // Recessed track
                RoundedRectangle(cornerRadius: 7)
                    .fill(LinearGradient(colors: [Color.black.opacity(0.65), Color(white: 0.11)], startPoint: .leading, endPoint: .trailing))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.10), lineWidth: 1))
                // Tick marks (every 10%, longer at 0 / 50 / 100)
                ForEach(0...10, id: \.self) { i in
                    let ty = handleHeight / 2 + CGFloat(i) / 10 * range
                    let major = i % 5 == 0
                    HStack {
                        tick(major); Spacer(); tick(major)
                    }
                    .frame(width: trackWidth - 4)
                    .offset(y: ty - 0.5)
                }
                // Slot + lit progress from the rest end to the handle
                Capsule().fill(Color.black.opacity(0.8)).frame(width: 5)
                    .padding(.vertical, handleHeight / 2)
                Capsule().fill(Theme.accent)
                    .frame(width: 5, height: max(0, abs(handleMid - restY)))
                    .offset(y: min(handleMid, restY))
                    .shadow(color: Theme.accent.opacity(0.8), radius: 4)
                    .opacity(progress > 0.001 ? 1 : 0)
                handle.offset(y: y)
            }
            .frame(width: trackWidth)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
                    .onChanged { v in
                        if grab == nil {
                            let off = v.startLocation.y - y
                            grab = (0...handleHeight).contains(off) ? off : handleHeight / 2
                        }
                        let top = v.location.y - (grab ?? handleHeight / 2)
                        let p = 1 - Double(min(max(top / max(range, 1), 0), 1))
                        if abs(p - model.tbar) > 0.0005 { model.setTBar(p) }
                    }
                    .onEnded { _ in grab = nil }
            )
        }
        .frame(width: trackWidth + 14, height: height)
    }

    private func tick(_ major: Bool) -> some View {
        Rectangle().fill(Color.white.opacity(major ? 0.45 : 0.2)).frame(width: major ? 6 : 3, height: 1)
    }

    /// Metallic lever cap with grip lines.
    private var handle: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(colors: [Color(white: 0.92), Color(white: 0.62), Color(white: 0.78)],
                                     startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.55), lineWidth: 1)
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle().fill(Color.black.opacity(0.35)).frame(height: 1)
                        .overlay(Rectangle().fill(Color.white.opacity(0.6)).frame(height: 1).offset(y: 1))
                }
            }
            .padding(.horizontal, 7)
            Rectangle().fill(progress > 0.001 || auto ? Theme.accent : Theme.program.opacity(0.85))
                .frame(height: 2).padding(.horizontal, 3).offset(y: handleHeight / 2 - 4)
        }
        .frame(width: trackWidth + 12, height: handleHeight)
        .shadow(color: .black.opacity(0.6), radius: 3, y: 2)
    }
}
#endif
