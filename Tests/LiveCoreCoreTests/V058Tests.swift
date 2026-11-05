import XCTest
@testable import LiveCoreCore

final class V058Tests: XCTestCase {
    func testQRPayloads() {
        var i = QRItem(kind: .url, text: " livecore.studio/a ")
        XCTAssertEqual(i.payload, "https://livecore.studio/a")
        i.text = "http://x.y"
        XCTAssertEqual(i.payload, "http://x.y")
        i.kind = .wifi; i.ssid = "Hall;A"; i.password = "p:w"
        XCTAssertEqual(i.payload, #"WIFI:T:WPA;S:Hall\;A;P:p\:w;;"#)
        i.security = .open; i.hiddenNetwork = true
        XCTAssertEqual(i.payload, #"WIFI:T:nopass;S:Hall\;A;H:true;;"#)
        i.kind = .whatsapp; i.phoneNumber = "0812-3456 789"; i.message = "Halo kak"
        XCTAssertEqual(i.payload, "https://wa.me/628123456789?text=Halo%20kak")
        i.kind = .phone
        XCTAssertEqual(i.payload, "tel:08123456789")
        i.kind = .email; i.emailAddress = "a@b.c"; i.message = ""
        XCTAssertEqual(i.payload, "mailto:a@b.c")
        i.kind = .vcard; i.contactName = "Budi, S.T."
        XCTAssertTrue(i.payload!.contains("FN:Budi\\, S.T.\r\n"))
        XCTAssertTrue(i.payload!.hasPrefix("BEGIN:VCARD\r\nVERSION:3.0"))
        i.kind = .payment; i.text = "  00020101021126…  "
        XCTAssertEqual(i.payload, "00020101021126…")
        i.kind = .image
        XCTAssertNil(i.payload)
        XCTAssertNil(QRItem(kind: .url, text: "  ").payload)
    }

    func testQRDesignRoundTripStepAndDefaults() throws {
        var d = QRDesign.template("angpao")
        d.items.append(QRItem(name: "B"))
        d.style.logoPath = "/tmp/logo.png"
        d.style.autoHide = 30
        XCTAssertEqual(d.style.effectiveCorrection, .high)
        let back = try JSONDecoder().decode(QRDesign.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back, d)
        d.step(1); XCTAssertEqual(d.selected, 1)
        d.step(1); XCTAssertEqual(d.selected, 0)
        d.step(-1); XCTAssertEqual(d.selected, 1)
        let partial = try JSONDecoder().decode(QRDesign.self, from: Data(#"{"selected":5,"style":{"size":0.4}}"#.utf8))
        XCTAssertEqual(partial.items.count, 1)
        XCTAssertEqual(partial.selected, 0)
        XCTAssertEqual(partial.style.size, 0.4)
        XCTAssertEqual(partial.style.anchor, .bottomRight)
        let src = ProjectSource.qrCode(d)
        XCTAssertEqual(try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(src)), src)
    }

    func testQRCardLayoutStaysInside() {
        var s = QRStyle()
        for a in QRAnchor.allCases {
            s.anchor = a
            let l = QRCardLayout.layout(s, width: 1920, height: 1080, titleLines: 1, captionLines: 2)
            XCTAssertGreaterThanOrEqual(l.card.x, 0); XCTAssertGreaterThanOrEqual(l.card.y, 0)
            XCTAssertLessThanOrEqual(l.card.x + l.card.width, 1920.001)
            XCTAssertLessThanOrEqual(l.card.y + l.card.height, 1080.001)
            XCTAssertEqual(l.code.width, 0.30 * 1080, accuracy: 0.01)
        }
        s.anchor = .bottomRight
        let l = QRCardLayout.layout(s, width: 1920, height: 1080, titleLines: 0, captionLines: 0)
        XCTAssertEqual(l.card.x + l.card.width, 1920 - 0.05 * 1080, accuracy: 0.01)
    }

    func testQRMatrixTrim() {
        // 4×4 bitmap with a 2×2 dark block at (1,1).
        let dark = [false, false, false, false,
                    false, true, true, false,
                    false, true, false, false,
                    false, false, false, false]
        let m = QRMatrix.trimmed(width: 4, height: 4, dark: dark)!
        XCTAssertEqual(m.size, 2)
        XCTAssertTrue(m[0, 0]); XCTAssertTrue(m[1, 0]); XCTAssertTrue(m[0, 1]); XCTAssertFalse(m[1, 1])
        XCTAssertNil(QRMatrix.trimmed(width: 2, height: 2, dark: [false, false, false, false]))
        let big = QRMatrix(size: 21, cells: .init(repeating: false, count: 441))
        XCTAssertTrue(big.isFinder(0, 0)); XCTAssertTrue(big.isFinder(20, 6)); XCTAssertTrue(big.isFinder(6, 20))
        XCTAssertFalse(big.isFinder(20, 20)); XCTAssertFalse(big.isFinder(10, 10))
    }

    func testHighlightRangesAndTimeline() {
        var s = HighlightSettings()
        s.preRoll = 10; s.postRoll = 5; s.crossfade = 1
        let marks = [HighlightMark(offset: 100), HighlightMark(offset: 30), HighlightMark(offset: 112),
                     HighlightMark(offset: 300, enabled: false), HighlightMark(offset: -4), HighlightMark(offset: 5)]
        let r = HighlightPlan.ranges(marks, duration: 200, settings: s)
        // 5 → 0...10, 30 → 20...35, 100 & 112 → 90...117 (merged).
        XCTAssertEqual(r, [0...10, 20...35, 90...117])
        let t = HighlightPlan.timeline(r, crossfade: 1)
        XCTAssertEqual(t.map(\.start), [0, 9, 23])
        XCTAssertEqual(HighlightPlan.totalDuration(t), 50)
        // A fade never takes more than half a short clip.
        XCTAssertEqual(HighlightPlan.transition(2, 1.5, 10), 0.75)
        // Gaps shorter than the crossfade are merged.
        XCTAssertEqual(HighlightPlan.ranges([HighlightMark(offset: 10), HighlightMark(offset: 25.5)], duration: 60, settings: s),
                       [0...30.5])
        XCTAssertEqual(HighlightPlan.ranges([HighlightMark(offset: 10), HighlightMark(offset: 27)], duration: 60, settings: s).count, 2)
    }

    func testHighlightSettingsSidecarAndRemote() throws {
        let old = try JSONDecoder().decode(HighlightSettings.self, from: Data(#"{"preRoll":3}"#.utf8))
        XCTAssertEqual(old.preRoll, 3); XCTAssertEqual(old.postRoll, 10); XCTAssertEqual(old.format, .landscape)
        XCTAssertEqual(HighlightSidecar.url(for: URL(fileURLWithPath: "/r/Show 1.mov")).lastPathComponent, "Show 1.highlights.json")
        let start = Date(timeIntervalSince1970: 1000)
        let m = HighlightPlan.marks([ShowMark(kind: .highlight, title: "kiss", date: start.addingTimeInterval(42)),
                                     ShowMark(kind: .chapter, title: "x", date: start)], recordingStart: start)
        XCTAssertEqual(m.count, 1); XCTAssertEqual(m[0].offset, 42); XCTAssertEqual(m[0].title, "kiss")
        XCTAssertTrue(ControlAction.catalog.contains(.highlight))

        func route(_ path: String, _ q: [String: String]) -> RemoteRoute {
            RemoteRouter.route(HTTPRequest(method: "POST", path: path, query: q, headers: [:], body: []))
        }
        XCTAssertEqual(route("/api/highlight", [:]), .command(.action(.highlight)))
        XCTAssertEqual(route("/api/qr/next", ["input": "3"]), .command(.qrItem(input: 3, delta: 1)))
        XCTAssertEqual(route("/api/qr/previous", ["input": "3"]), .command(.qrItem(input: 3, delta: -1)))
        XCTAssertEqual(route("/api/qr/item", ["input": "2", "item": "4"]), .command(.qrItemSet(input: 2, item: 4)))
        XCTAssertEqual(route("/api/qr/show", ["input": "2"]), .command(.qrShow(input: 2)))
        XCTAssertEqual(route("/api/qr/show", [:]), .badRequest("input"))
        var st = RemoteState()
        st.highlights = 3
        st.qrs = [.init(number: 4, name: "QR – Angpao", on: true, item: 1, items: ["Angpao", "Materi"])]
        XCTAssertTrue(st.json.contains(#""highlights":3"#))
        XCTAssertTrue(st.json.contains(#""items":["Angpao","Materi"]"#))
    }
}
