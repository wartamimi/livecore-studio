import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.46.0: scene layouts and editing helpers, vertical framing, wedding and meeting templates.
final class Release046Tests: XCTestCase {
    func testNewSceneLayoutsHaveTheirSlotCounts() {
        XCTAssertEqual(SceneTemplate.allCases.count, 17)
        XCTAssertEqual(SceneTemplate.grid3x3.slots.count, 9)
        XCTAssertEqual(SceneTemplate.sidebar.slots.count, 4)
        XCTAssertEqual(SceneTemplate.panel4.slots.count, 4)
        XCTAssertEqual(SceneTemplate.oneOverThree.slots.count, 4)
    }

    func testAlignAndDistribute() {
        let r = NormRect(x: 0.3, y: 0.2, width: 0.2, height: 0.4)
        XCTAssertEqual(LayerEditing.align(r, .right).x, 0.8, accuracy: 1e-9)
        XCTAssertEqual(LayerEditing.align(r, .centerY).y, 0.3, accuracy: 1e-9)
        XCTAssertEqual(LayerEditing.align(r, .left).width, 0.2)
        let rs = [NormRect(x: 0.6, y: 0, width: 0.2, height: 0.2), NormRect(x: 0, y: 0, width: 0.2, height: 0.2)]
        let d = LayerEditing.distribute(rs, horizontal: true)
        // 1 - 0.4 = 0.6 free, 3 gaps of 0.2; the left box (index 1) stays first.
        XCTAssertEqual(d[1].x, 0.2, accuracy: 1e-9)
        XCTAssertEqual(d[0].x, 0.6, accuracy: 1e-9)
        let dup = LayerEditing.duplicate(Layer(source: InputID("a"), rect: r))
        XCTAssertEqual(dup.rect.x, 0.33, accuracy: 1e-9)
        XCTAssertEqual(dup.source, InputID("a"))
    }

    func testVerticalZoomAndFit() {
        let src = PixelSize(width: 1920, height: 1080)
        let r = VerticalCrop.rect(source: src, aspect: 9.0 / 16, centerX: 0.5, zoom: 2, centerY: 0)
        XCTAssertEqual(r.height, 540, accuracy: 1e-6)
        XCTAssertEqual(r.y, 0, accuracy: 1e-6, "kept inside at the top")
        let f = VerticalCrop.fitRect(source: src, output: PixelSize(width: 1080, height: 1920), position: 0.5)
        XCTAssertEqual(f.width, 1080, accuracy: 1e-6)
        XCTAssertEqual(f.height, 607.5, accuracy: 1e-6)
        XCTAssertEqual(f.y, (1920 - 607.5) / 2, accuracy: 1e-6)
    }

    func testOldVerticalSettingsStillDecode() throws {
        let json = #"{"enabled":true,"size":{"width":1080,"height":1920},"follow":"center","manualX":0.5,"smoothing":0.06,"streamURL":"","keychainAccount":"vertical","bitrateKbps":6000,"recordWithProgram":false}"#
        let v = try JSONDecoder().decode(VerticalSettings.self, from: Data(json.utf8))
        XCTAssertEqual(v.bitrateKbps, 6000)
        XCTAssertEqual(v.fill, .crop)
        XCTAssertEqual(v.zoom, 1)
        XCTAssertEqual(v.audioBitrateKbps, 128)
        var w = v; w.fill = .fitBlur; w.zoom = 1.5
        XCTAssertEqual(try JSONDecoder().decode(VerticalSettings.self, from: JSONEncoder().encode(w)), w)
    }

    func testWeddingAndMeetingTemplates() {
        XCTAssertEqual(TitleTemplate.weddingCenter.category, .title)
        XCTAssertEqual(TitleTemplate.weddingFloral.category, .lowerThird)
        XCTAssertNotEqual(TitleTemplate.weddingFloral.defaultDesign.textAnimation, .off)
        XCTAssertEqual(TickerTemplate.weddingGold.config(text: "x").template, .weddingGold)
        for t in [FrameTemplate.conference, .meeting, .webinar, .keynote] {
            let l = FrameLayout.layout(t, aspect: 16.0 / 9)
            XCTAssertLessThanOrEqual(l.camera.x + l.camera.width, 1 + 1e-9, "\(t)")
            XCTAssertLessThanOrEqual(l.camera.y + l.camera.height, 1 + 1e-9, "\(t)")
            XCTAssertNotNil(l.label)
        }
    }
}
