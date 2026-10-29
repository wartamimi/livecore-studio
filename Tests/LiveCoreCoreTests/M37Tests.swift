import Foundation
import XCTest
@testable import LiveCoreCore
@testable import LiveCoreServices

/// 0.37.0: stability (autosave / recovery, undo, file log, diagnostics) and the evaluation's
/// features (LUFS, ducking, pre-flight, templates, title data sources, PTZ).
final class M37Tests: XCTestCase {
    private func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lc-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: Autosave / recovery

    func testCleanQuitOffersNoRecovery() throws {
        let store = AutosaveStore(directory: tempDir())
        XCTAssertNil(store.beginSession())
        XCTAssertTrue(try store.save(Data("a".utf8), projectPath: nil))
        store.endSession()
        XCTAssertNil(AutosaveStore(directory: store.directory).beginSession(), "clean quit")
    }

    func testCrashOffersLastAutosave() throws {
        let dir = tempDir()
        let first = AutosaveStore(directory: dir)
        first.beginSession()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try first.save(Data("v1".utf8), projectPath: "/Shows/wedding.livecore", now: t)
        XCTAssertFalse(try first.save(Data("v1".utf8), projectPath: nil), "unchanged data is not written again")
        try first.save(Data("v2".utf8), projectPath: "/Shows/wedding.livecore", now: t.addingTimeInterval(30))
        // no endSession: the app crashed
        let second = AutosaveStore(directory: dir)
        let r = try XCTUnwrap(second.beginSession())
        XCTAssertEqual(r.projectPath, "/Shows/wedding.livecore")
        XCTAssertEqual(r.savedAt, t.addingTimeInterval(30))
        XCTAssertEqual(second.recoveryData(), Data("v2".utf8))
        // A damaged latest file falls back to the previous one.
        XCTAssertEqual(second.recoveryData { $0 != Data("v2".utf8) }, Data("v1".utf8))
        second.discard()
        XCTAssertNil(second.recoveryData())
        second.endSession()
        XCTAssertNil(AutosaveStore(directory: dir).beginSession())
    }

    func testCrashWithoutAutosaveOffersNothing() {
        let dir = tempDir()
        AutosaveStore(directory: dir).beginSession()
        XCTAssertNil(AutosaveStore(directory: dir).beginSession(), "nothing was saved yet")
    }

    // MARK: File log and diagnostics

    func testFileLogRotatesAndRedacts() throws {
        let log = FileLog(directory: tempDir(), maxBytes: 10_000, keep: 2)
        log.addSecret("live_abcd1234")
        log.error("publish failed for live_abcd1234")
        for i in 0..<400 { log.info("line \(i) " + String(repeating: "x", count: 40)) }
        log.flush()
        let files = log.files()
        XCTAssertGreaterThanOrEqual(files.count, 2)
        XCTAssertLessThanOrEqual(files.count, 3)
        let all = try files.map { try String(contentsOf: $0, encoding: .utf8) }.joined()
        XCTAssertFalse(all.contains("live_abcd1234"))
        for f in files { XCTAssertLessThanOrEqual(try Data(contentsOf: f).count, 10_000 + 200) }
    }

    func testDiagnosticsNeverContainKeys() throws {
        var b = DiagnosticsBundle()
        b.secrets = ["1234"]   // too short to scrub safely: ignored
        b.sections = [.init(title: "Stream", lines: [
            "url rtmp://a.rtmp.youtube.com/live2/abcd-efgh-ijkl-mnop end",
            "srt://host:9000?mode=caller&passphrase=topsecret&latency=200",
            "rtmps://live-api-s.facebook.com:443/rtmp/FB-1234-0-Abc",
        ])]
        let s = b.summary()
        XCTAssertFalse(s.contains("abcd-efgh"))
        XCTAssertTrue(s.contains("rtmp://a.rtmp.youtube.com/live2/<redacted> end"))
        XCTAssertFalse(s.contains("topsecret"))
        XCTAssertTrue(s.contains("latency=200"))
        XCTAssertFalse(s.contains("FB-1234"))
        b.files = ["settings.json": #"{"serverURL":"rtmp://x.example/app/streamkey99"}"#]
        let dir = try b.write(into: tempDir(), name: "diag")
        let settings = try String(contentsOf: dir.appendingPathComponent("settings.json"), encoding: .utf8)
        XCTAssertFalse(settings.contains("streamkey99"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("summary.txt").path))
    }

    // MARK: Undo

    func testEditHistoryCoalescesDrags() {
        var h = EditHistory(0, limit: 3, coalesce: 0.5)
        h.record(1, now: 0)
        h.record(2, now: 0.1)     // same drag
        h.record(3, now: 0.2)
        h.record(10, now: 2)      // new step
        XCTAssertEqual(h.undoCount, 2)
        XCTAssertEqual(h.undo(), 3)
        XCTAssertEqual(h.undo(), 0)
        XCTAssertNil(h.undo())
        XCTAssertEqual(h.redo(), 3)
        XCTAssertEqual(h.redo(), 10)
        XCTAssertNil(h.redo())
        h.undo()
        h.record(5, now: 3)
        XCTAssertFalse(h.canRedo, "a new edit clears redo")
        for i in 0..<10 { h.breakCoalescing(); h.record(100 + i, now: 4) }
        XCTAssertEqual(h.undoCount, 3, "bounded")
        h.reset(7)
        XCTAssertFalse(h.canUndo)
        XCTAssertEqual(h.current, 7)
    }

    // MARK: Loudness

    private func loudness(amplitude: Float, seconds: Double, frequency: Double = 1000) -> LoudnessMeter {
        var m = LoudnessMeter()
        let n = Int(seconds * 48_000)
        var l = [Float](repeating: 0, count: n), r = l
        for i in 0..<n {
            let v = amplitude * Float(sin(2 * .pi * frequency * Double(i) / 48_000))
            l[i] = v; r[i] = v
        }
        l.withUnsafeBufferPointer { lp in r.withUnsafeBufferPointer { rp in
            var i = 0
            while i < n { let c = min(512, n - i); m.process(left: lp.baseAddress! + i, right: rp.baseAddress! + i, frames: c); i += c }
        } }
        return m
    }

    func testEBUReferenceToneReads23LUFS() {
        // EBU Tech 3341: 1 kHz stereo sine at -23 dBFS reads -23.0 LUFS (±0.1).
        let m = loudness(amplitude: powf(10, -23 / 20), seconds: 5)
        XCTAssertEqual(m.momentary, -23, accuracy: 0.1)
        XCTAssertEqual(m.shortTerm, -23, accuracy: 0.1)
        XCTAssertEqual(m.integrated, -23, accuracy: 0.1)
        let quiet = loudness(amplitude: powf(10, -33 / 20), seconds: 4)
        XCTAssertEqual(quiet.integrated, -33, accuracy: 0.1)
    }

    func testSilenceIsGatedOut() {
        var m = loudness(amplitude: 0, seconds: 2)
        XCTAssertEqual(m.integrated, LoudnessMeter.silence)
        XCTAssertEqual(m.integratedBlocks, 0)
        m.reset()
        XCTAssertEqual(m.momentary, LoudnessMeter.silence)
    }

    // MARK: Ducking

    func testDuckerAttackHoldRelease() {
        var s = DuckingSettings()
        s.enabled = true; s.depthDB = -12; s.attackMs = 100; s.holdMs = 200; s.releaseMs = 400
        var d = Ducker()
        let dt: Float = 0.01
        for _ in 0..<5 { _ = d.step(triggerPeakDB: -10, seconds: dt, settings: s) }
        XCTAssertEqual(d.gainDB, -6, accuracy: 0.01, "half way after half the attack")
        for _ in 0..<10 { _ = d.step(triggerPeakDB: -10, seconds: dt, settings: s) }
        XCTAssertEqual(d.gainDB, -12, accuracy: 0.001)
        for _ in 0..<15 { _ = d.step(triggerPeakDB: -80, seconds: dt, settings: s) }
        XCTAssertEqual(d.gainDB, -12, accuracy: 0.001, "held")
        for _ in 0..<25 { _ = d.step(triggerPeakDB: -80, seconds: dt, settings: s) }
        XCTAssertGreaterThan(d.gainDB, -12)
        for _ in 0..<50 { _ = d.step(triggerPeakDB: -80, seconds: dt, settings: s) }
        XCTAssertEqual(d.gainDB, 0)
        s.enabled = false
        _ = d.step(triggerPeakDB: 0, seconds: dt, settings: s)
        XCTAssertEqual(d.gainDB, 0)
    }

    func testDuckingSettingsClampAndDecode() throws {
        var s = DuckingSettings()
        s.depthDB = -100; s.thresholdDB = .nan
        XCTAssertEqual(s.clamped.depthDB, -40)
        XCTAssertEqual(s.clamped.thresholdDB, -35)
        let partial = try JSONDecoder().decode(DuckingSettings.self, from: Data(#"{"enabled":true,"depthDB":-99}"#.utf8))
        XCTAssertTrue(partial.enabled)
        XCTAssertEqual(partial.depthDB, -40)
        XCTAssertEqual(partial.releaseMs, 900)
        var a = ProjectAudio()
        a.ducking = s.clamped
        XCTAssertEqual(try roundTrip(a), a)
    }

    // MARK: Pre-flight

    func testPreflightFindsTheUsualProblems() {
        var f = PreflightFacts()
        f.willStream = true; f.willRecord = true
        f.inputCount = 3; f.programSet = true
        f.streamDestinations = 1; f.destinationsMissingKey = ["YouTube"]
        f.serverReachable = false
        f.microphone = .denied
        f.masterPeakDB = -90; f.programChannels = 2
        f.freeDiskBytes = 2_000_000_000; f.recordKbps = 12_000; f.plannedMinutes = 120
        let items = Preflight.check(f)
        let keys = Set(items.map(\.key))
        XCTAssertTrue(keys.isSuperset(of: ["preflight.stream_key", "preflight.server_unreachable", "preflight.mic_denied",
                                           "preflight.audio_silent", "preflight.disk_low"]))
        XCTAssertEqual(Preflight.overall(items), .problem)
        // 2 GB at 12 Mbit/s = 22 minutes.
        XCTAssertEqual(items.first { $0.key == "preflight.disk_low" }?.args, ["2.0", "22"])

        var good = PreflightFacts()
        good.willRecord = true; good.inputCount = 2; good.programSet = true
        good.masterPeakDB = -12; good.programChannels = 1
        good.freeDiskBytes = 500_000_000_000; good.recordKbps = 12_000
        XCTAssertEqual(Preflight.overall(Preflight.check(good)), .ok)
        XCTAssertEqual(Preflight.format1(2.25), "2.3")
        XCTAssertEqual(Preflight.format1(0.04), "0.0")
    }

    // MARK: Project templates

    func testTemplatesBuildConsistentProjects() throws {
        let cams = (1...4).map { ProjectTemplate.Device(uniqueID: "cam\($0)", name: "Cam \($0)") }
        let mics = [ProjectTemplate.Device(uniqueID: "mic1", name: "Wireless")]
        for t in ProjectTemplate.allCases {
            let doc = t.document(cameras: cams, microphones: mics)
            XCTAssertEqual(doc.validationIssues(), [], "\(t)")
            XCTAssertEqual(doc.sanitized(), doc, "\(t)")
            XCTAssertNotNil(doc.programInput)
            XCTAssertFalse(doc.overlays.isEmpty)
            XCTAssertEqual(try roundTrip(doc), doc)
        }
        let wedding = ProjectTemplate.wedding.document(cameras: cams, microphones: mics)
        XCTAssertEqual(wedding.inputs.filter { if case .camera = $0.source { return true }; return false }.count, 3)
        XCTAssertEqual(wedding.audio.ducking?.enabled, true)
        XCTAssertEqual(wedding.audio.channels.first?.duckTrigger, true)
        XCTAssertEqual(wedding.audio.music?.first?.channel?.duckTarget, true)
        let noDevices = ProjectTemplate.meeting.document(cameras: [], microphones: [])
        XCTAssertEqual(noDevices.validationIssues(), [])
        XCTAssertNotNil(noDevices.programInput)
    }

    // MARK: Data sources

    func testCSVParsing() {
        let t = CSVTable.parse("\u{FEFF}Name;Role\r\n\"Lestari, Ana\";\"Ketua \"\"Panitia\"\"\"\r\nBudi;\"MC\nAcara\"\n\n")
        XCTAssertEqual(t.header, ["Name", "Role"])
        XCTAssertEqual(t.rows.count, 2)
        XCTAssertEqual(t.rows[0], ["Lestari, Ana", "Ketua \"Panitia\""])
        XCTAssertEqual(t.rows[1], ["Budi", "MC\nAcara"])
        XCTAssertEqual(t.value(row: 1, column: "Role"), "MC\nAcara")
        XCTAssertNil(t.value(row: 5, column: "Role"))
        XCTAssertEqual(t.label(row: 0), "1 · Lestari, Ana")
        let tabs = CSVTable.parse("a\tb\n1\t2")
        XCTAssertEqual(tabs.rows, [["1", "2"]])
        let comma = CSVTable.parse("x,,z\n1,2\n")
        XCTAssertEqual(comma.header, ["x", "Column 2", "z"])
        XCTAssertEqual(comma.value(row: 0, column: "z"), "")
        XCTAssertEqual(CSVTable.parse("").header, [])
    }

    func testDataSourceRowsAndSheetsLinks() throws {
        let table = CSVTable.parse("Nama,Jabatan,Kota\nAna,Ketua,Bandung\nBudi,MC,Solo")
        var ds = TitleDataSource(kind: .file, location: "/x.csv", row: 7)
        ds.pickDefaultColumns(table)
        XCTAssertEqual(ds.titleColumn, "Nama")
        XCTAssertEqual(ds.subtitleColumn, "Jabatan")
        XCTAssertEqual(ds.row, 1)
        XCTAssertEqual(ds.text(in: table)?.title, "Budi")
        XCTAssertEqual(ds.text(in: table)?.subtitle, "MC")
        ds.row = 9
        XCTAssertNil(ds.text(in: table))
        XCTAssertEqual(TitleDataSource.downloadURL(for: "https://docs.google.com/spreadsheets/d/1AbC_d-9/edit#gid=12345"),
                       "https://docs.google.com/spreadsheets/d/1AbC_d-9/export?format=csv&gid=12345")
        XCTAssertEqual(TitleDataSource.downloadURL(for: " https://docs.google.com/spreadsheets/d/XYZ/edit "),
                       "https://docs.google.com/spreadsheets/d/XYZ/export?format=csv&gid=0")
        let published = "https://docs.google.com/spreadsheets/d/e/2PACX-1/pub?output=csv"
        XCTAssertEqual(TitleDataSource.downloadURL(for: published), published)
        XCTAssertEqual(TitleDataSource.downloadURL(for: "https://example.com/a.csv"), "https://example.com/a.csv")
        var style = ProjectTitleStyle(title: "a", subtitle: "b")
        style.dataSource = ds
        XCTAssertEqual(try roundTrip(style), style)
        XCTAssertNil(TitleDataSource(kind: .url, location: "", refreshSeconds: 0).refreshInterval)
        XCTAssertEqual(TitleDataSource(kind: .url, location: "", refreshSeconds: 1).refreshInterval, 5)
    }

    // MARK: PTZ

    func testVISCACommands() {
        XCTAssertEqual(VISCA.bytes(.panTilt(pan: .left, tilt: .up, panSpeed: 8, tiltSpeed: 8)),
                       [0x81, 0x01, 0x06, 0x01, 0x08, 0x08, 0x01, 0x01, 0xFF])
        XCTAssertEqual(VISCA.bytes(.panTilt(pan: .stop, tilt: .stop, panSpeed: 99, tiltSpeed: 99)),
                       [0x81, 0x01, 0x06, 0x01, 0x18, 0x14, 0x03, 0x03, 0xFF])
        XCTAssertEqual(VISCA.bytes(.home), [0x81, 0x01, 0x06, 0x04, 0xFF])
        XCTAssertEqual(VISCA.bytes(.zoom(.tele(3))), [0x81, 0x01, 0x04, 0x07, 0x23, 0xFF])
        XCTAssertEqual(VISCA.bytes(.zoom(.wide(9))), [0x81, 0x01, 0x04, 0x07, 0x37, 0xFF])
        XCTAssertEqual(VISCA.bytes(.zoom(.stop)), [0x81, 0x01, 0x04, 0x07, 0x00, 0xFF])
        XCTAssertEqual(VISCA.bytes(.recallPreset(2), address: 2), [0x82, 0x01, 0x04, 0x3F, 0x02, 0x02, 0xFF])
        XCTAssertEqual(VISCA.bytes(.storePreset(5)), [0x81, 0x01, 0x04, 0x3F, 0x01, 0x05, 0xFF])
        let p = VISCA.sonyPacket(VISCA.bytes(.home), sequence: 0x0102_0304)
        XCTAssertEqual(p, [0x01, 0x00, 0x00, 0x05, 0x01, 0x02, 0x03, 0x04, 0x81, 0x01, 0x06, 0x04, 0xFF])
        let raw = PTZConfig(host: "10.0.0.5", transport: .tcp)
        XCTAssertEqual(raw.port, 5678)
        XCTAssertEqual(VISCA.packet(.home, config: raw, sequence: 1), [0x81, 0x01, 0x06, 0x04, 0xFF])
    }

    func testPTZConfigClampsAndRoundTrips() throws {
        var c = PTZConfig(host: " 192.168.1.20 ", port: 0, address: 9, speed: 0, presetNames: Array(repeating: "x", count: 12))
        c = c.clamped
        XCTAssertEqual(c.host, "192.168.1.20")
        XCTAssertEqual(c.port, 52381)
        XCTAssertEqual(c.address, 7)
        XCTAssertEqual(c.speed, 1)
        XCTAssertEqual(c.presetNames.count, PTZConfig.presetCount)
        XCTAssertEqual(c.presetName(0), "x")
        XCTAssertEqual(PTZConfig(host: "h").presetName(3), "4")
        var pi = ProjectInput(id: InputID("c"), name: "Cam", source: .camera(uniqueID: "u", deviceName: "Cam"))
        pi.ptz = c
        XCTAssertEqual(try roundTrip(pi), pi)
    }

    func testXLSXSheetParsing() {
        let shared = """
        <sst xmlns="x"><si><t>Name</t></si><si><t>Role</t></si><si><r><t>Ana </t></r><r><t>Lestari</t></r></si>\
        <si><t>漢字</t><rPh><t>かんじ</t></rPh></si></sst>
        """
        let sheet = """
        <worksheet><sheetData>
        <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
        <row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>12.0</v></c></row>
        <row r="3"></row>
        <row r="4"><c r="A4" t="inlineStr"><is><t>Budi</t></is></c><c r="B4" t="b"><v>1</v></c></row>
        <row r="5"><c r="A5" t="s"><v>3</v></c></row>
        </sheetData></worksheet>
        """
        let t = XLSXReader.parse(sharedStrings: Data(shared.utf8), sheet: Data(sheet.utf8))
        XCTAssertEqual(t.header, ["Name", "Role", ""])
        XCTAssertEqual(t.rows.count, 3)
        XCTAssertEqual(t.rows[0], ["Ana Lestari", "", "12"])
        XCTAssertEqual(t.rows[1], ["Budi", "TRUE", ""])
        XCTAssertEqual(t.rows[2][0], "漢字")
        XCTAssertEqual(t.value(row: 0, column: "Name"), "Ana Lestari")
        XCTAssertEqual(XLSXReader.cellRef("AB12"), XLSXReader.CellRef(row: 11, col: 27))
    }

    func testXLSXFileUsesFirstSheetInWorkbookOrder() throws {
        let dir = tempDir()
        let fm = FileManager.default
        func write(_ path: String, _ text: String) throws {
            let u = dir.appendingPathComponent("src/" + path)
            try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: u)
        }
        try write("xl/workbook.xml", #"<workbook><sheets><sheet name="Tamu" sheetId="2" r:id="rId7"/><sheet name="Lain" sheetId="1" r:id="rId1"/></sheets></workbook>"#)
        try write("xl/_rels/workbook.xml.rels", #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId7" Target="worksheets/sheet2.xml"/></Relationships>"#)
        try write("xl/worksheets/sheet1.xml", #"<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Wrong</t></is></c></row></sheetData></worksheet>"#)
        try write("xl/worksheets/sheet2.xml", #"<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Nama</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Citra</t></is></c></row></sheetData></worksheet>"#)
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = dir.appendingPathComponent("src")
        zip.arguments = ["-q", "-r", dir.appendingPathComponent("book.xlsx").path, "xl"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let t = try XLSXReader.table(at: dir.appendingPathComponent("book.xlsx"))
        XCTAssertEqual(t.header, ["Nama"])
        XCTAssertEqual(t.rows, [["Citra"]])
        try Data("not a zip".utf8).write(to: dir.appendingPathComponent("bad.xlsx"))
        XCTAssertThrowsError(try XLSXReader.table(at: dir.appendingPathComponent("bad.xlsx")))
    }

    func testCompanionRoutesForPTZAndDataRows() {
        func route(_ path: String, _ q: [String: String], _ m: String = "POST") -> RemoteRoute {
            RemoteRouter.route(HTTPRequest(method: m, path: path, query: q))
        }
        XCTAssertEqual(route("/api/ptz/preset", ["input": "2", "preset": "3"]), .command(.ptzPreset(input: 2, preset: 3)))
        XCTAssertEqual(route("/api/ptz/preset", ["input": "2", "preset": "9"]), .badRequest("preset"))
        XCTAssertEqual(route("/api/ptz/home", ["input": "4"]), .command(.ptzHome(input: 4)))
        XCTAssertEqual(route("/api/data/next", ["input": "5"]), .command(.dataRow(input: 5, delta: 1)))
        XCTAssertEqual(route("/api/data/previous", ["input": "5"]), .command(.dataRow(input: 5, delta: -1)))
        XCTAssertEqual(route("/api/data/row", ["input": "5", "row": "3"]), .command(.dataRowSet(input: 5, row: 3)))
        XCTAssertEqual(route("/api/data/row", ["input": "5", "row": "0"]), .badRequest("row"))
        XCTAssertEqual(route("/api/data/next", ["input": "5"], "GET"), .methodNotAllowed)
    }
}

final class WatchdogTests: XCTestCase {
    func testReportsABlockedQueueAndStaysQuietOtherwise() {
        let target = DispatchQueue(label: "watched")
        let dog = MainThreadWatchdog(target: target, interval: 0.02, threshold: 0.15)
        let lock = NSLock()
        var list: [Int] = []
        dog.onStall = { ms in lock.lock(); list.append(ms); lock.unlock() }
        func stalls() -> [Int] { lock.lock(); defer { lock.unlock() }; return list }
        dog.start()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(stalls().isEmpty, "no stall while the queue answers")
        target.async { Thread.sleep(forTimeInterval: 0.4) }
        Thread.sleep(forTimeInterval: 0.7)
        dog.stop()
        XCTAssertEqual(stalls().count, 1)
        XCTAssertGreaterThanOrEqual(stalls().first ?? 0, 300)
    }
}
