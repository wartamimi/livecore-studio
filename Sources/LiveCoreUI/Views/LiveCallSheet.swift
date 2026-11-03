#if os(macOS)
import AppKit
import SwiftUI
import LiveCoreCore
import LiveCoreEngine

/// LCS Live (0.52.0): guest link, call status, return feed and TURN settings of one call input.
struct LiveCallSheet: View {
    let input: InputID
    @EnvironmentObject var model: AppModel
    @ObservedObject private var service = LiveCallService.shared
    @ObservedObject private var tunnel = LiveCallService.shared.tunnel
    @Environment(\.dismiss) private var dismiss
    @State private var config = ProjectLiveCall()
    @State private var turn = LiveCallICE()
    @State private var advanced = false
    @State private var confirmOnline = false
    @State private var keyVersion = 0

    var body: some View {
        let src = model.liveCallSource(input)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("LCS Live").font(.title3.bold())
                Spacer()
                status
            }
            Text(L10n.t("lcslive.about")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            if let e = service.error { Text(e).font(.caption).foregroundStyle(Theme.warning) }
            if let src {
                GroupBox(L10n.t("lcslive.online")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let link = service.onlineLink(src) {
                            linkRow(link)
                            if let img = RemoteSettingsView.qr(link) {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 120, height: 120)
                            }
                        } else if tunnel.running {
                            HStack { ProgressView().controlSize(.small); Text(L10n.t("remote.online_starting")).font(.caption) }
                        } else {
                            Button(L10n.t("lcslive.online_start")) { confirmOnline = true }.disabled(RemoteTunnel.executable == nil)
                        }
                        if RemoteTunnel.executable == nil {
                            Text(L10n.t("remote.online_install")).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled)
                        }
                        if let e = tunnel.error { Text(e).font(.caption).foregroundStyle(Theme.warning) }
                        Text(L10n.t("lcslive.online_note")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(L10n.t("lcslive.test")) {
                    VStack(alignment: .leading, spacing: 6) {
                        if let l = service.localLink(src) {
                            HStack {
                                linkRow(l)
                                Button(L10n.t("lcslive.open")) { if let u = URL(string: l) { NSWorkspace.shared.open(u) } }
                            }
                        }
                        Text(L10n.t("lcslive.test_note")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                .id(keyVersion)
            }
            Form {
                TextField(L10n.t("lcslive.title"), text: $config.title)
                Toggle(L10n.t("lcslive.return_video"), isOn: $config.returnVideo)
                Toggle(L10n.t("lcslive.return_audio"), isOn: $config.returnAudio)
            }
            DisclosureGroup(L10n.t("lcslive.advanced"), isExpanded: $advanced) {
                Form {
                    TextField(L10n.t("lcslive.turn_url"), text: $turn.turnURL, prompt: Text("turn:turn.example.com:3478"))
                    TextField(L10n.t("lcslive.turn_user"), text: $turn.turnUser)
                    SecureField(L10n.t("lcslive.turn_password"), text: $turn.turnPassword)
                }
                Text(L10n.t("lcslive.turn_note")).font(.caption).foregroundStyle(Theme.textDim).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let src {
                    Button(L10n.t("lcslive.new_link")) { service.newLink(src); keyVersion += 1 }
                    if case .connected = src.callState { Button(L10n.t("lcslive.hangup"), role: .destructive) { src.hangUp() } }
                    else if case .connecting = src.callState { Button(L10n.t("lcslive.hangup"), role: .destructive) { src.hangUp() } }
                }
                Spacer()
                Button(L10n.t("settings.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L10n.t("settings.apply")) {
                    service.ice = turn
                    if let src { service.apply(config, to: src) }
                    dismiss()
                }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            if let s = model.liveCallSource(input) { config = s.config }
            turn = service.ice
        }
        .alert(L10n.t("remote.online_confirm_title"), isPresented: $confirmOnline) {
            Button(L10n.t("lcslive.online_start")) { service.startOnline() }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("lcslive.online_confirm"))
        }
    }

    private var status: some View {
        let st = service.states[input] ?? .waiting
        let (text, color): (String, Color) = {
            switch st {
            case .waiting: return (L10n.t("lcslive.waiting"), Theme.textDim)
            case let .connecting(n): return (L10n.f("lcslive.connecting", n), Theme.warning)
            case let .connected(n): return (L10n.f("lcslive.connected", n), .green)
            case let .ended(n): return (L10n.f("lcslive.ended", n), Theme.textDim)
            }
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 9, height: 9)
            Text(text).font(.system(size: 12, weight: .semibold))
        }
    }

    private func linkRow(_ s: String) -> some View {
        HStack {
            Text(s).font(.system(size: 11).monospaced()).textSelection(.enabled).lineLimit(2)
            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string) } label: {
                Image(systemName: "doc.on.doc")
            }.buttonStyle(.borderless).help(L10n.t("lcslive.copy"))
        }
    }
}
#endif
