#if os(macOS)
import SwiftUI

/// Animated LiveCore logo shown over the main window when the app opens (0.72.0).
///
/// The engine starts behind it (AppDelegate starts the model before the window draws), so the
/// splash adds no waiting time. A click or any key skips it; Settings › Appearance turns it off,
/// and with Reduce Motion it fades in and out without moving parts.
struct SplashView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 0 → nothing, 1 → orange L, 2 → white blocks, 3 → wordmark, 4 → LIVE dot + bar.
    @State private var phase = 0
    @State private var pulse = false
    @State private var sweep: CGFloat = 0
    @State private var leaving = false
    @State private var finished = false

    private static let total: Double = 3.8

    init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

    var body: some View {
        ZStack {
            RadialGradient(colors: [Color(red: 0.13, green: 0.10, blue: 0.09), Color.black],
                           center: .center, startRadius: 10, endRadius: 700)
            // Broadcast rings behind the logo.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(LiveCoreLogo.orange.opacity(0.22 - Double(i) * 0.06), lineWidth: 1.5)
                    .frame(width: 190 + CGFloat(i) * 70, height: 190 + CGFloat(i) * 70)
                    .scaleEffect(pulse && !reduceMotion ? 1.12 : 0.9)
                    .opacity(phase >= 2 ? (pulse ? 0.15 : 1) : 0)
                    .animation(reduceMotion ? nil : .easeOut(duration: 1.6).repeatForever(autoreverses: false)
                        .delay(Double(i) * 0.25), value: pulse)
            }
            VStack(spacing: 26) {
                LiveCoreLogo(phase: phase, reduceMotion: reduceMotion)
                    .frame(width: 132, height: 132)
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        Text("Live").foregroundStyle(LiveCoreLogo.orange)
                        Text("Core").foregroundStyle(.white)
                    }
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                    HStack(spacing: 8) {
                        Circle().fill(Color.red)
                            .frame(width: 9, height: 9)
                            .shadow(color: .red, radius: pulse ? 6 : 1)
                            .opacity(phase >= 4 ? 1 : 0)
                        Text("STUDIO")
                            .font(.system(size: 13, weight: .semibold))
                            .tracking(phase >= 3 ? 9 : 2)
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
                .opacity(phase >= 3 ? 1 : 0)
                .offset(y: phase >= 3 || reduceMotion ? 0 : 14)
                // Loading bar: a light sweep while the engine starts behind the splash.
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    Capsule().fill(LinearGradient(colors: [LiveCoreLogo.orange.opacity(0), LiveCoreLogo.orange, .white],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: 220 * sweep)
                }
                .frame(width: 220, height: 3)
                .opacity(phase >= 4 ? 1 : 0)
            }
        }
        .ignoresSafeArea()
        .opacity(leaving ? 0 : 1)
        .scaleEffect(leaving && !reduceMotion ? 1.04 : 1)
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .background(SplashKeyCatcher { finish() })
        .onAppear(perform: run)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("LiveCore Studio"))
    }

    private func run() {
        let steps: [(Double, Int)] = reduceMotion ? [(0, 4)] : [(0.1, 1), (0.7, 2), (1.4, 3), (2.0, 4)]
        for (t, p) in steps {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                withAnimation(reduceMotion ? .easeIn(duration: 0.3) : .spring(response: 0.8, dampingFraction: 0.75)) { phase = p }
                if p == 2 { pulse = true }
                if p == 4 { withAnimation(.easeInOut(duration: Self.total - t - 0.35)) { sweep = 1 } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.total) { finish() }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        withAnimation(.easeInOut(duration: 0.6)) { leaving = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.62) { onFinish() }
    }
}

/// The LiveCore mark drawn as shapes (orange L with three white blocks, like the app icon), so
/// every piece can animate on its own and it stays sharp at any size.
struct LiveCoreLogo: View {
    static let orange = Color(red: 0.96, green: 0.42, blue: 0.08)
    var phase = 4
    var reduceMotion = false

    var body: some View {
        GeometryReader { g in
            let s = min(g.size.width, g.size.height) / 100
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 22 * s, style: .continuous)
                    .fill(Color.black)
                    .overlay(RoundedRectangle(cornerRadius: 22 * s, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 1))
                    .shadow(color: Self.orange.opacity(phase >= 2 ? 0.35 : 0), radius: 24 * s)
                // Orange L: grows up from the bottom.
                LShape()
                    .fill(LinearGradient(colors: [Self.orange, Color(red: 0.75, green: 0.25, blue: 0.03)],
                                         startPoint: .top, endPoint: .bottom))
                    .frame(width: 40 * s, height: 64 * s)
                    .offset(x: 18 * s, y: 18 * s)
                    .scaleEffect(x: 1, y: phase >= 1 || reduceMotion ? 1 : 0.01, anchor: .bottom)
                    .opacity(phase >= 1 ? 1 : 0)
                block(x: 40, y: 18, w: 42, h: 30, s: s, step: 2, from: CGSize(width: 0, height: -30))
                block(x: 62, y: 52, w: 20, h: 30, s: s, step: 2, from: CGSize(width: 30, height: 0))
                block(x: 40, y: 52, w: 18, h: 14, s: s, step: 3, from: CGSize(width: 0, height: 20))
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func block(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, s: CGFloat, step: Int, from: CGSize) -> some View {
        let shown = phase >= step
        return RoundedRectangle(cornerRadius: 3 * s, style: .continuous)
            .fill(Color.white.opacity(0.96))
            .frame(width: w * s, height: h * s)
            .offset(x: x * s + (shown || reduceMotion ? 0 : from.width * s),
                    y: y * s + (shown || reduceMotion ? 0 : from.height * s))
            .opacity(shown ? 1 : 0)
    }
}

/// The L of the logo: a tall bar with a foot to the right.
private struct LShape: Shape {
    func path(in r: CGRect) -> Path {
        let bar = r.width * 0.45, foot = r.height * 0.25, rad = r.width * 0.08
        var p = Path()
        p.move(to: CGPoint(x: r.minX + rad, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + bar, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + bar, y: r.maxY - foot))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - foot))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + rad, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - rad), control: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + rad))
        p.addQuadCurve(to: CGPoint(x: r.minX + rad, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// Any key press while the splash shows skips it (the key is swallowed so it cannot switch inputs).
private struct SplashKeyCatcher: NSViewRepresentable {
    let onKey: () -> Void

    final class Coordinator {
        var monitor: Any?
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let action = onKey
        context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { _ in
            action()
            return nil
        }
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let m = coordinator.monitor { NSEvent.removeMonitor(m); coordinator.monitor = nil }
    }
}
#endif
