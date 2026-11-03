#if os(macOS)
import AppKit
import Foundation
import LiveCoreCore
import LiveCoreEngine
import LiveCoreServices
import Network

/// Operator / Advanced mode, project templates, title data sources, PTZ, ducking and loudness.
extension AppModel {
    // MARK: Operator / Advanced mode

    public enum UIMode: String, CaseIterable { case operatorMode = "operator", advanced }

    static let uiModeKey = "uiMode"

    /// The Operator/Advanced switch was removed in 0.38.0 (user's call): always the full interface,
    /// also for anyone who had switched to Operator mode in 0.37.0.
    static func loadUIMode() -> UIMode {
        UserDefaults.standard.removeObject(forKey: uiModeKey)
        return .advanced
    }

    /// Operator mode hides set-up tools (codecs, capture card options, ISO, MIDI, NDI, shaders,
    /// experimental inputs) so the show screen only has what is needed during the event.
    public var isOperatorMode: Bool { uiMode == .operatorMode }

    public func setUIMode(_ m: UIMode) {
        uiMode = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.uiModeKey)
    }

    // MARK: Project templates

    public func inputID(number n: Int) -> InputID? { inputs.first { $0.number == n }?.id }

    /// Replaces the production with a template built from the connected cameras and microphones.
    public func newFromTemplate(_ t: ProjectTemplate) {
        guard let e = engine else { return }
        if !inputs.isEmpty {
            let alert = NSAlert()
            alert.messageText = L10n.t("project.new_confirm")
            alert.addButton(withTitle: L10n.t("common.ok"))
            alert.addButton(withTitle: L10n.t("settings.cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var texts = ProjectTemplate.Texts()
        texts.camera = L10n.t("template.text.camera")
        texts.music = L10n.t("template.text.music")
        texts.coupleNames = L10n.t("template.text.couple")
        texts.weddingDate = L10n.t("template.text.wedding_date")
        texts.welcome = L10n.t("template.text.welcome")
        texts.speaker = L10n.t("template.text.speaker")
        texts.speakerRole = L10n.t("template.text.role")
        texts.startingSoon = L10n.t("template.text.starting")
        texts.eventTitle = L10n.t("template.text.event")
        texts.guest = L10n.t("template.text.guest")
        let cams = videoDevices.filter(\.isConnected).map { ProjectTemplate.Device(uniqueID: $0.id, name: $0.name) }
        let mics = audioDevices.filter(\.isConnected).map { ProjectTemplate.Device(uniqueID: $0.id, name: $0.name) }
        let doc = t.document(cameras: cams, microphones: mics, texts: texts, settings: settings)
        var warnings: [String] = []
        withUndoSuspended { warnings = e.loadProject(doc, projectDirectory: nil) }
        clearUndo()
        projectURL = nil
        afterProjectLoad()
        setOutputRouting(OutputRouting())
        multiCorder = MultiCorderConfig()
        applyInputGroups(from: doc)
        warnings.forEach(report)
        FileLog.shared.info("new project from template \(t.rawValue): \(cams.count) cameras, \(mics.count) microphones")
    }

    // MARK: Title data sources (CSV / Google Sheets)

    public func dataSource(_ id: InputID) -> TitleDataSource? { textSource(id)?.style.dataSource }

    /// Connects a title to a table (nil disconnects) and shows the selected row.
    public func setDataSource(_ ds: TitleDataSource?, for id: InputID) {
        guard let src = textSource(id) else { return }
        var st = src.style
        st.dataSource = ds
        engine?.updateTitle(id, style: st)
        dataTimers.removeValue(forKey: id)?.invalidate()
        if ds == nil { dataTables[id] = nil; dataErrors[id] = nil; return }
        loadDataSource(id)
    }

    /// Reads the file or downloads the link, then applies the selected row.
    public func loadDataSource(_ id: InputID, completion: ((CSVTable?) -> Void)? = nil) {
        guard let ds = dataSource(id) else { completion?(nil); return }
        Self.readTable(ds) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(table):
                self.dataTables[id] = table
                self.dataErrors[id] = nil
                self.applyDataRow(id)
                completion?(table)
            case let .failure(err):
                self.dataErrors[id] = err.localizedDescription
                self.report(L10n.f("data.load_failed", err.localizedDescription))
                completion?(nil)
            }
            self.scheduleDataRefresh(id)
        }
    }

    private func scheduleDataRefresh(_ id: InputID) {
        dataTimers.removeValue(forKey: id)?.invalidate()
        guard let ds = dataSource(id), ds.kind == .url, let every = ds.refreshInterval else { return }
        let t = Timer(timeInterval: every, repeats: false) { [weak self] _ in self?.loadDataSource(id) }
        RunLoop.main.add(t, forMode: .common)
        dataTimers[id] = t
    }

    /// Table from a file (UTF-8, else Windows Latin) or a link (main-thread completion).
    public static func readTable(_ ds: TitleDataSource, completion: @escaping (Result<CSVTable, Error>) -> Void) {
        switch ds.kind {
        case .file:
            let url = URL(fileURLWithPath: ds.location)
            if url.pathExtension.lowercased() == "xlsx" {
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = Result { try XLSXReader.table(at: url) }
                    DispatchQueue.main.async { completion(result) }
                }
                return
            }
            do {
                let data = try Data(contentsOf: url)
                let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? ""
                completion(.success(CSVTable.parse(text)))
            } catch { completion(.failure(error)) }
        case .url:
            guard let url = URL(string: TitleDataSource.downloadURL(for: ds.location)), ["http", "https"].contains(url.scheme ?? "") else {
                completion(.failure(URLError(.badURL))); return
            }
            var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            req.setValue("text/csv, text/plain, */*", forHTTPHeaderField: "Accept")
            URLSession.shared.dataTask(with: req) { data, resp, err in
                let result: Result<CSVTable, Error>
                if let err { result = .failure(err) }
                else if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    result = .failure(URLError(.badServerResponse, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"]))
                } else {
                    let d = data ?? Data()
                    let text = String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? ""
                    // A Sheets link that is not shared publicly answers with the sign-in page.
                    if text.lowercased().contains("<html") {
                        result = .failure(URLError(.userAuthenticationRequired, userInfo: [NSLocalizedDescriptionKey: L10n.t("data.not_public")]))
                    } else {
                        result = .success(CSVTable.parse(text))
                    }
                }
                DispatchQueue.main.async { completion(result) }
            }.resume()
        }
    }

    /// Shows the selected row's text in the title.
    public func applyDataRow(_ id: InputID) {
        guard let src = textSource(id), let ds = src.style.dataSource, let table = dataTables[id],
              let text = ds.text(in: table) else { return }
        var st = src.style
        st.title = text.title
        st.subtitle = text.subtitle
        guard st != src.style else { return }
        engine?.updateTitle(id, style: st)
        objectWillChange.send()
    }

    public func setDataRow(_ id: InputID, _ row: Int) {
        guard let src = textSource(id), var ds = src.style.dataSource else { return }
        let count = dataTables[id]?.rows.count ?? 0
        ds.row = SlideMath.clamp(row, count: count)
        var st = src.style
        st.dataSource = ds
        engine?.updateTitle(id, style: st)
        applyDataRow(id)
    }

    public func stepDataRow(_ id: InputID, by delta: Int) {
        guard let ds = dataSource(id) else { return }
        setDataRow(id, ds.row + delta)
    }

    /// After a project load: reads every title's table again.
    func reloadAllDataSources() {
        dataTimers.values.forEach { $0.invalidate() }
        dataTimers = [:]
        dataTables = [:]
        for i in inputs where dataSource(i.id) != nil { loadDataSource(i.id) }
    }

    // MARK: PTZ

    public func ptzConfig(_ id: InputID) -> PTZConfig? { engine?.ptzConfigs[id] }

    public func setPTZ(_ c: PTZConfig?, for id: InputID) {
        engine?.setPTZ(c, for: id)
        ptzStatus[id] = nil
        objectWillChange.send()
    }

    public func ptz(_ command: VISCA.Command, input id: InputID) {
        engine?.ptz(command, input: id) { [weak self] status in
            if self?.ptzStatus[id] != status { self?.ptzStatus[id] = status }
        }
    }

    // MARK: Ducking and loudness

    public var ducking: DuckingSettings {
        get { engine?.mixer.ducking.settings ?? DuckingSettings() }
        set { engine?.mixer.ducking.settings = newValue; objectWillChange.send() }
    }

    public func resetLoudness() { engine?.mixer.loudnessResets.add() }
}
#endif
