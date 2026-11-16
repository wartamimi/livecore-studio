import XCTest
@testable import LiveCoreCore
@testable import LiveCoreServices

/// 0.80.0: Missing Files dialog helpers and LiveCore's own .pptx reader.
final class V080Tests: XCTestCase {
    func testMissingMediaAndRelink() {
        var doc = ProjectDocument(settings: ProductionSettings())
        doc.inputs = [
            ProjectInput(id: InputID("a"), name: "A", source: .image(path: "/old/logo.png", relativePath: "logo.png")),
            ProjectInput(id: InputID("b"), name: "B", source: .videoFile(path: "/ok/clip.mov", relativePath: nil, loop: false)),
            ProjectInput(id: InputID("c"), name: "C", source: .presentation(ProjectPresentation(file: ProjectMediaRef(path: "/old/Deck.pptx")))),
        ]
        let present: Set<String> = ["/ok/clip.mov", "/proj/logo.png"]
        // logo.png is found next to the project, so only the deck is missing.
        XCTAssertEqual(doc.missingMedia(projectDirectory: "/proj", exists: present.contains), ["/old/Deck.pptx"])
        let moves = MissingMedia.matches(missing: ["/old/Deck.pptx"], candidates: ["/new/x.png", "/new/sub/deck.PPTX"])
        XCTAssertEqual(moves, ["/old/Deck.pptx": "/new/sub/deck.PPTX"])
        let fixed = doc.relinked(moves)
        guard case let .presentation(p) = fixed.inputs[2].source else { return XCTFail() }
        XCTAssertEqual(p.file.path, "/new/sub/deck.PPTX")
        XCTAssertEqual(fixed.missingMedia(projectDirectory: "/proj", exists: (present.union(["/new/sub/deck.PPTX"])).contains), [])
    }

    func testPPTXDeck() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pptx-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ns = #"xmlns:a="a" xmlns:p="p" xmlns:r="r""#
        func rels(_ items: [(String, String, String)]) -> String {
            "<Relationships>" + items.map { #"<Relationship Id="\#($0.0)" Type="x/\#($0.1)" Target="\#($0.2)"/>"# }.joined() + "</Relationships>"
        }
        let files: [String: String] = [
            "ppt/presentation.xml": #"<p:presentation \#(ns)><p:sldIdLst><p:sldId id="256" r:id="rId1"/><p:sldId id="257" r:id="rId2"/></p:sldIdLst><p:sldSz cx="12192000" cy="6858000"/></p:presentation>"#,
            "ppt/_rels/presentation.xml.rels": rels([("rId1", "slide", "slides/slide1.xml"), ("rId2", "slide", "slides/slide2.xml")]),
            "ppt/slides/slide1.xml": #"<p:sld \#(ns)><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:p><a:r><a:rPr lang="en"/><a:t>Hello</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="127000" y="254000"/><a:ext cx="1270000" cy="635000"/></a:xfrm><a:prstGeom prst="ellipse"/><a:solidFill><a:schemeClr val="accent1"><a:lumMod val="50000"/></a:schemeClr></a:solidFill></p:spPr></p:sp></p:spTree></p:cSld></p:sld>"#,
            "ppt/slides/_rels/slide1.xml.rels": rels([("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml")]),
            "ppt/slides/slide2.xml": #"<p:sld \#(ns) show="0"><p:cSld><p:spTree/></p:cSld></p:sld>"#,
            "ppt/slideLayouts/slideLayout1.xml": #"<p:sldLayout \#(ns)><p:cSld><p:spTree/></p:cSld></p:sldLayout>"#,
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels": rels([("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")]),
            "ppt/slideMasters/slideMaster1.xml": #"<p:sldMaster \#(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill></p:bgPr></p:bg><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type="title"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="12700" cy="25400"/></a:xfrm></p:spPr></p:sp></p:spTree></p:cSld><p:clrMap bg1="dk1" tx1="lt1"/><p:txStyles><p:titleStyle><a:lvl1pPr algn="ctr"><a:defRPr sz="4400"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill><a:latin typeface="+mj-lt"/></a:defRPr></a:lvl1pPr></p:titleStyle></p:txStyles></p:sldMaster>"#,
            "ppt/slideMasters/_rels/slideMaster1.xml.rels": rels([("rId1", "theme", "../theme/theme1.xml")]),
            "ppt/theme/theme1.xml": #"<a:theme \#(ns)><a:themeElements><a:clrScheme><a:dk1><a:srgbClr val="000000"/></a:dk1><a:lt1><a:srgbClr val="FFFFFF"/></a:lt1><a:accent1><a:srgbClr val="FF0000"/></a:accent1></a:clrScheme><a:fontScheme><a:majorFont><a:latin typeface="Georgia"/></a:majorFont><a:minorFont><a:latin typeface="Arial"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>"#,
        ]
        for (path, xml) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try xml.write(to: url, atomically: true, encoding: .utf8)
        }
        let deck = try PPTXParser(directory: dir).deck()
        XCTAssertEqual(deck.width, 960, accuracy: 0.01)
        XCTAssertEqual(deck.slides.count, 1, "hidden slide skipped")
        let s = deck.slides[0]
        XCTAssertEqual(s.background, .black, "bg1 mapped to dk1")
        XCTAssertEqual(s.shapes.count, 2)
        let title = s.shapes[0]
        XCTAssertEqual(title.frame, PPTXRect(x: 0, y: 0, width: 1, height: 2), "position from the master placeholder")
        let run = try XCTUnwrap(title.text?.paragraphs.first?.runs.first)
        XCTAssertEqual(run.text, "Hello")
        XCTAssertEqual(run.size, 44)
        XCTAssertEqual(run.font, "Georgia")
        XCTAssertEqual(run.color, .white)
        XCTAssertEqual(title.text?.paragraphs.first?.align, .center)
        let oval = s.shapes[1]
        XCTAssertEqual(oval.geometry, .ellipse)
        XCTAssertEqual(oval.frame, PPTXRect(x: 10, y: 20, width: 100, height: 50))
        XCTAssertEqual(oval.fill?.r ?? 0, 0.5, accuracy: 0.01, "lumMod 50% darkens the red")
    }

    func testPPTXSampleFile() throws {
        // Optional: a real deck made by PowerPoint/python-pptx (set LC_PPTX_SAMPLE to run it).
        guard let path = ProcessInfo.processInfo.environment["LC_PPTX_SAMPLE"] else { return }
        try PPTXParser.withDeck(URL(fileURLWithPath: path)) { deck in
            for (i, s) in deck.slides.enumerated() {
                print("slide \(i + 1) bg \(s.background) shapes \(s.shapes.count)")
                for sh in s.shapes {
                    print("  \(sh.geometry) \(sh.frame) fill \(String(describing: sh.fill)) img \(sh.image != nil) text \(sh.text?.paragraphs.map { ($0.bullet ?? "") + $0.runs.map(\.text).joined() + " \(Int($0.runs.first?.size ?? 0))pt" } ?? [])")
                }
            }
        }
    }
}
