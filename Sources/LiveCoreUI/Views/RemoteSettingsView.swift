#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import LiveCoreCore

/// Settings › Remote: the Web Controller (switch from a phone or tablet browser on the same
/// network). The PIN and the QR code stay hidden until asked for, so they never show up on a
/// screen-capture input or a shared screen by accident.
struct RemoteSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var portField = ""
    @State private var showPIN = false
    @State private var showQR = false

    var body: some View {
        Form {
            Toggle(L10n.t("remote.enable"), isOn: Binding(get: { model.remoteEnabled }, set: { model.setRemoteEnabled($0) }))
            Text(L10n.t("remote.about")).font(.caption).foregroundStyle(Theme.textDim)
            HStack {
                TextField(L10n.t("remote.port"), text: $portField).frame(width: 160)
                Button(L10n.t("settings.apply")) { model.setRemotePort(Int(portField) ?? model.remotePort); portField = "\(model.remotePort)" }
                    .disabled(Int(portField) == model.remotePort)
            }
            if let err = model.remoteError {
                Text(err).font(.caption).foregroundStyle(Theme.warning)
            }
            if model.remoteEnabled {
                HStack {
                    Text("PIN")
                    Text(showPIN ? model.remotePIN : String(repeating: "•", count: model.remotePIN.count))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .textSelection(.enabled)
                    Button { showPIN.toggle() } label: { Image(systemName: showPIN ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                        .help(L10n.t(showPIN ? "remote.hide" : "remote.show"))
                    Spacer()
                    Button(L10n.t("remote.new_pin")) { model.newRemotePIN() }
                        .help(L10n.t("remote.new_pin.help"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.t("remote.open")).font(.caption).foregroundStyle(Theme.textDim)
                    if model.remoteURLs.isEmpty {
                        Text(L10n.t("remote.no_network")).foregroundStyle(Theme.warning)
                    }
                    ForEach(model.remoteURLs, id: \.self) { url in
                        HStack {
                            Text(url).font(.system(size: 13).monospaced()).textSelection(.enabled)
                            Button { copy(url) } label: { Image(systemName: "doc.on.doc") }
                                .buttonStyle(.borderless).help(L10n.t("remote.copy"))
                        }
                    }
                }
                if let url = model.remoteURLs.first {
                    DisclosureGroup(L10n.t("remote.qr"), isExpanded: $showQR) {
                        HStack(alignment: .top, spacing: 12) {
                            if let img = Self.qr("\(url)/#pin=\(model.remotePIN)") {
                                Image(nsImage: img).interpolation(.none).resizable().frame(width: 150, height: 150)
                            }
                            Text(L10n.t("remote.qr.help")).font(.caption).foregroundStyle(Theme.textDim)
                        }
                        .padding(.top, 4)
                    }
                }
                Text(L10n.f("remote.clients", model.remoteClients)).font(.caption).foregroundStyle(Theme.textDim)
                RemoteOnlineSection(tunnel: model.remoteTunnel, port: model.remotePort, pin: model.remotePIN)
            }
            Text(L10n.t("remote.security")).font(.caption).foregroundStyle(Theme.warning)
        }
        .padding(8)
        .onAppear { portField = "\(model.remotePort)" }
        .onDisappear { showPIN = false; showQR = false }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    /// QR code of `text`, scaled up with whole pixels so it stays sharp.
    static func qr(_ text: String) -> NSImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "M"
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: out)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
    }
}

/// Online access (outside the local Wi-Fi) through a Cloudflare quick tunnel (0.45.0).
struct RemoteOnlineSection: View {
    @ObservedObject var tunnel: RemoteTunnel
    let port: Int
    let pin: String
    @State private var confirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Text(L10n.t("remote.online")).font(.system(size: 12, weight: .semibold))
            Text(L10n.t("remote.online_about")).font(.caption).foregroundStyle(Theme.textDim)
            if RemoteTunnel.executable == nil {
                Text(L10n.t("remote.online_install")).font(.caption).foregroundStyle(Theme.warning).textSelection(.enabled)
            }
            HStack {
                if tunnel.running {
                    Button(L10n.t("remote.online_stop"), role: .destructive) { tunnel.stop() }
                    if tunnel.url == nil { ProgressView().controlSize(.small); Text(L10n.t("remote.online_starting")).font(.caption) }
                } else {
                    Button(L10n.t("remote.online_start")) { confirm = true }
                        .disabled(RemoteTunnel.executable == nil)
                }
            }
            if let u = tunnel.url {
                HStack {
                    Text(u).font(.system(size: 12).monospaced()).textSelection(.enabled)
                    Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(u, forType: .string) } label: {
                        Image(systemName: "doc.on.doc")
                    }.buttonStyle(.borderless)
                }
                if let img = RemoteSettingsView.qr("\(u)/#pin=\(pin)") {
                    Image(nsImage: img).interpolation(.none).resizable().frame(width: 130, height: 130)
                }
            }
            if let e = tunnel.error { Text(e).font(.caption).foregroundStyle(Theme.warning) }
            Text(L10n.t("remote.online_tailscale")).font(.caption).foregroundStyle(Theme.textDim)
        }
        .alert(L10n.t("remote.online_confirm_title"), isPresented: $confirm) {
            Button(L10n.t("remote.online_start")) { tunnel.start(port: port) }
            Button(L10n.t("settings.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.t("remote.online_confirm_message"))
        }
    }
}
#endif
