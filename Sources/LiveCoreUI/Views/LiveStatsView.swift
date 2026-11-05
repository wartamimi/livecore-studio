#if os(macOS)
import SwiftUI

/// Signals live readings (meters aside): performance, recording and stream stats (0.48.0).
public final class LiveStats: ObservableObject {}

/// Redraws only its content when a live reading changes, not the whole window.
struct Live<Content: View>: View {
    @ObservedObject var stats: LiveStats
    let content: () -> Content
    init(_ stats: LiveStats, @ViewBuilder content: @escaping () -> Content) {
        self.stats = stats
        self.content = content
    }
    var body: some View { content() }
}
#endif
