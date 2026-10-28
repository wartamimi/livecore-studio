#if os(macOS)
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices

/// Online radio (0.38.0): search the free Radio Browser directory and play a station into its own
/// mixer channel.
extension AppModel {
    public var radioInputs: [RadioInput] { engine?.radios ?? [] }
    public func radio(_ channelID: String) -> RadioInput? { engine?.radio(channelID: channelID) }

    /// Searches the directory, trying the mirrors in turn. Completion on the main thread.
    public func searchRadio(_ query: RadioBrowser.Query, completion: @escaping (Result<[RadioStation], Error>) -> Void) {
        func attempt(_ servers: ArraySlice<String>, lastError: Error?) {
            guard let server = servers.first, let url = RadioBrowser.searchURL(server: server, query) else {
                DispatchQueue.main.async { completion(.failure(lastError ?? URLError(.cannotFindHost))) }
                return
            }
            var req = URLRequest(url: url, timeoutInterval: 12)
            req.setValue(RadioBrowser.userAgent, forHTTPHeaderField: "User-Agent")
            URLSession.shared.dataTask(with: req) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if let data, error == nil, status == 200, let list = try? RadioBrowser.decodeStations(data, limit: query.limit) {
                    DispatchQueue.main.async { completion(.success(list)) }
                } else {
                    attempt(servers.dropFirst(), lastError: error ?? URLError(.badServerResponse))
                }
            }.resume()
        }
        attempt(RadioBrowser.servers[...], lastError: nil)
    }

    /// Adds the station to the mixer and starts it.
    public func addRadio(_ station: RadioStation, play: Bool = true) {
        guard let e = engine else { return }
        let r = e.addRadio(station)
        FileLog.shared.info("online radio added: \(station.name)")
        if play { r.play() }
        reloadAudioChannels()
    }

    public func removeRadio(_ channelID: String) {
        guard let r = engine?.radio(channelID: channelID) else { return }
        engine?.removeRadio(id: r.id)
        reloadAudioChannels()
    }

    static func radioStateText(_ s: RadioInput.State) -> String {
        switch s {
        case .stopped: return L10n.t("radio.stopped")
        case .connecting: return L10n.t("radio.connecting")
        case .buffering: return L10n.t("radio.buffering")
        case .playing: return L10n.t("radio.playing")
        case let .reconnecting(sec): return L10n.f("radio.reconnecting", String(format: "%.0f", sec))
        case let .failed(reason): return L10n.f("radio.failed", reason)
        }
    }
}
#endif
