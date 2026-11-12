#if os(macOS)
import SwiftUI

// Shared dialog building blocks (0.73.2). Every sheet gets the same background, accent and
// header from here, so a style change is made once instead of in each dialog.

/// Theme for a dialog: background, accent and forms on the theme colour (no system grey).
struct DialogChrome: ViewModifier {
    let model: AppModel

    func body(content: Content) -> some View {
        content
            .environmentObject(model)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.accent)
    }
}

extension View {
    /// `sheet(item:)` with the app's dialog theme and model.
    func dialog<Item: Identifiable, Content: View>(item: Binding<Item?>, _ model: AppModel,
                                                  @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item) { content($0).modifier(DialogChrome(model: model)) }
    }

    /// `sheet(isPresented:)` with the app's dialog theme and model.
    func dialog<Content: View>(isPresented: Binding<Bool>, _ model: AppModel,
                               @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented) { content().modifier(DialogChrome(model: model)) }
    }
}

/// Dialog title bar: icon chip in the state colour, title and subtitle, extra controls, Close.
struct DialogHeader<Trailing: View>: View {
    let icon: String
    let title: String
    var subtitle: String? = nil
    var color: Color = Theme.accent
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            IconChip(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline).lineLimit(1).truncationMode(.tail)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.textDim).lineLimit(1) }
            }
            Spacer(minLength: 8)
            trailing()
            Button(L10n.t("common.close"), action: close).keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Theme.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

extension DialogHeader where Trailing == EmptyView {
    init(icon: String, title: String, subtitle: String? = nil, color: Color = Theme.accent, close: @escaping () -> Void) {
        self.init(icon: icon, title: title, subtitle: subtitle, color: color, close: close) { EmptyView() }
    }
}

/// Icon on a soft tile of its colour (dialog headers and titles).
struct IconChip: View {
    let icon: String
    var color: Color = Theme.accent

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: 30, height: 30)
            .background(color.opacity(0.16))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Title line of a small dialog (add-input sheets): the input type's icon chip and the title,
/// the same icon as in the Add Input menu so the dialog is recognised at a glance (0.75.1).
struct DialogTitle: View {
    let icon: String
    let title: String

    init(_ icon: String, _ title: String) { self.icon = icon; self.title = title }

    var body: some View {
        HStack(spacing: 10) {
            IconChip(icon: icon)
            Text(title).font(.headline).lineLimit(1)
        }
        .padding(.bottom, 2)
    }
}

/// Small number badge in the tally colour (input tiles, Properties header).
struct TallyBadge: View {
    let number: Int
    let color: Color?

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .heavy).monospacedDigit())
            .foregroundStyle(Color.white)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(color ?? Color.black.opacity(0.6))
            .clipShape(Capsule())
    }
}

/// One row of a side list (Settings, input Properties): icon in a small chip, the chosen row
/// filled with the accent.
struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(selected ? 0.22 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title).font(.system(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 7).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Theme.text)
            .background(shape.fill(selected ? Theme.accent : (hovering ? Theme.panelHover : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: selected)
    }
}
#endif
