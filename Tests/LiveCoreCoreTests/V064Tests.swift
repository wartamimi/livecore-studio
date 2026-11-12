import XCTest
@testable import LiveCoreCore

final class V064Tests: XCTestCase {
    func testTitlePackageRoundTrip() throws {
        let p = TitlePackage(name: "Gold", title: "Rina", subtitle: "Dimas", design: TitleTemplate.gold3D.defaultDesign)
        let back = try JSONDecoder().decode(TitlePackage.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
        XCTAssertEqual(back.kind, .title)
        XCTAssertTrue(back.isValid)
        XCTAssertEqual(back.fontFamilies, ["Didot"])
    }

    func testTickerPackageDropsLocalPath() throws {
        var c = TickerTemplate.neon3D.config(text: "x")
        c.textFilePath = "/Users/me/news.txt"
        let p = TitlePackage(name: "Neon", ticker: c)
        XCTAssertNil(p.ticker?.textFilePath)
        XCTAssertEqual(p.kind, .ticker)
        let json = #"{"name":"T","ticker":\#(String(data: try JSONEncoder().encode(c), encoding: .utf8)!),"fonts":["a.ttf","../x.ttf",".hidden","f/g.otf"]}"#
        let q = try JSONDecoder().decode(TitlePackage.self, from: Data(json.utf8))
        XCTAssertEqual(q.kind, .ticker)          // inferred
        XCTAssertNil(q.ticker?.textFilePath)
        XCTAssertEqual(q.fonts, ["a.ttf"])       // unsafe names dropped
    }

    func testPartialAndNewerFiles() throws {
        // Unknown keys and a newer format still open; a missing design is not valid.
        let q = try JSONDecoder().decode(TitlePackage.self, from: Data(#"{"format":7,"name":"X","future":true,"design":{"template":"newsFlip3D"}}"#.utf8))
        XCTAssertTrue(q.isValid)
        XCTAssertEqual(q.design?.template, .newsFlip3D)
        XCTAssertEqual(q.design, TitleTemplate.newsFlip3D.defaultDesign)
        let empty = try JSONDecoder().decode(TitlePackage.self, from: Data(#"{"name":"X"}"#.utf8))
        XCTAssertFalse(empty.isValid)
    }

    func testFileName() {
        XCTAssertEqual(TitlePackage.fileName(for: "News: Live/Now?"), "News LiveNow.lctitle")
        XCTAssertEqual(TitlePackage.fileName(for: "  ..  "), "Template.lctitle")
    }
}
