import XCTest
@testable import LiveCoreCore

final class V059Tests: XCTestCase {
    private func roundTrip<T: Codable>(_ v: T) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
    }

    // MARK: Virtual Set

    func testTwelveStudios() throws {
        XCTAssertEqual(VirtualSetTemplate.allCases.count, 12)
        for t in VirtualSetTemplate.allCases {
            let d = t.defaultDesign
            XCTAssertEqual(d, d.clamped, "\(t)")
            XCTAssertFalse(t.spots.isEmpty)
            XCTAssertEqual(try roundTrip(d), d)
            let p = VirtualSetPlacement.place(d, aspect: 16.0 / 9.0)
            XCTAssertEqual(p.talents.count, t.spots.count)
            for (s, tal) in zip(t.spots, p.talents) {
                // The talent box ends at the desk top when there is a desk.
                if let desk = s.desk { XCTAssertEqual(tal.rect.y + tal.rect.height, desk, accuracy: 1e-9, "\(t)") }
                XCTAssertGreaterThanOrEqual(tal.cropBottom, 0)
                XCTAssertLessThanOrEqual(tal.cropBottom, 0.45)
                XCTAssertGreaterThan(tal.rect.height, 0.3)
            }
            if let s = t.screen {
                XCTAssertGreaterThanOrEqual(s.x, 0); XCTAssertLessThanOrEqual(s.x + s.width, 1)
            }
        }
    }

    func testShotZoomKeepsTheSetOnCanvas() {
        var d = VirtualSetTemplate.debateStage.defaultDesign
        for shot in VirtualSetShot.allCases {
            d.shot = shot
            let p = VirtualSetPlacement.place(d, aspect: 16.0 / 9.0)
            XCTAssertEqual(p.zoom, shot.zoom)
            // The visible window stays inside the drawn studio.
            XCTAssertGreaterThanOrEqual(p.originX, 0); XCTAssertLessThanOrEqual(p.originX + 1 / p.zoom, 1 + 1e-9)
            XCTAssertGreaterThanOrEqual(p.originY, 0); XCTAssertLessThanOrEqual(p.originY + 1 / p.zoom, 1 + 1e-9)
        }
        d.shot = .close
        let wide = VirtualSetPlacement.place(VirtualSetTemplate.debateStage.defaultDesign, aspect: 16.0 / 9.0)
        let close = VirtualSetPlacement.place(d, aspect: 16.0 / 9.0)
        XCTAssertEqual(close.talents[0].rect.height, wide.talents[0].rect.height * 1.8, accuracy: 1e-9)
    }

    func testDeskCutOffAndClamp() throws {
        var d = VirtualSetTemplate.newsDesk.defaultDesign
        d.deskCut = false
        XCTAssertEqual(VirtualSetPlacement.place(d, aspect: 16.0 / 9.0).talents[0].cropBottom, 0)
        d.talentScale = 9; d.talentOffsetX = -4; d.talents = ["a", "b", "c"]
        let c = d.clamped
        XCTAssertEqual(c.talentScale, 1.6); XCTAssertEqual(c.talentOffsetX, -0.3)
        XCTAssertEqual(c.talents, ["a"])
        // Older / partial files fall back to the template defaults.
        let partial = try JSONDecoder().decode(VirtualSetDesign.self, from: Data(#"{"template":"goldGala"}"#.utf8))
        XCTAssertEqual(partial, VirtualSetTemplate.goldGala.defaultDesign)
        XCTAssertEqual(try roundTrip(ProjectSource.virtualSet(d.clamped)), .virtualSet(d.clamped))
    }

    // MARK: 3D

    func testMotionPoses() {
        for m in Motion3D.allCases {
            XCTAssertTrue(m.pose(progress: 1).isRest, "\(m)")
            if m != .off {
                XCTAssertFalse(m.pose(progress: 0.3).isRest, "\(m)")
                XCTAssertLessThan(m.pose(progress: 0).opacity, 0.01, "\(m) starts hidden")
            }
        }
        XCTAssertEqual(Motion3D.flipUp.pose(progress: 0).rotX, 90, accuracy: 1e-9)
        XCTAssertEqual(Motion3D.swingLeft.pose(progress: 0).pivotX, 0)
    }

    func testProjection() {
        // At rest the box is unchanged.
        let c = Projection3D.corners(x: 100, y: 800, w: 600, h: 120, pose: .rest, distance: 2000)
        XCTAssertEqual(c[0].x, 100, accuracy: 1e-9); XCTAssertEqual(c[2].y, 920, accuracy: 1e-9)
        // Turned 60° around its bottom edge, away from the viewer: the top comes down and gets narrower.
        let p = Pose3D(rotX: 60, pivotY: 1)
        let t = Projection3D.corners(x: 100, y: 800, w: 600, h: 120, pose: p, distance: 2000)
        XCTAssertGreaterThan(t[0].y, 800)
        XCTAssertEqual(t[3].y, 920, accuracy: 1e-6)
        XCTAssertLessThan(t[1].x - t[0].x, 600)
        // Swung around the left edge: the left edge stays, the right edge recedes.
        let s = Projection3D.corners(x: 0, y: 0, w: 400, h: 100, pose: Pose3D(rotY: 45, pivotX: 0), distance: 2000)
        XCTAssertEqual(s[0].x, 0, accuracy: 1e-9)
        XCTAssertLessThan(s[1].x, 400 * 0.75)
        XCTAssertLessThan(s[2].y - s[1].y, 100)
    }

    func testTitle3DTemplatesAndCoding() throws {
        let threeD = TitleTemplate.allCases.filter { $0.defaultDesign.active3D != nil }
        XCTAssertEqual(threeD.count, 8)
        var d = TitleTemplate.chrome3D.defaultDesign
        XCTAssertEqual(try roundTrip(d), d)
        // Turning 3D off is kept after saving (the template default does not come back).
        d.look3D = .flat
        XCTAssertNil(d.active3D)
        XCTAssertNil(try roundTrip(d).active3D)
        // Older titles stay flat.
        XCTAssertNil(TitleTemplate.classicStrap.defaultDesign.active3D)
        var x = Title3D(depth: 500, tiltX: 90, duration: 0)
        x = x.clamped
        XCTAssertEqual(x.depth, 60); XCTAssertEqual(x.tiltX, 35); XCTAssertEqual(x.duration, 0.2)
    }

    func testTicker3D() throws {
        let c = TickerTemplate.chrome3D.config(text: "x")
        XCTAssertTrue(c.is3D); XCTAssertTrue(c.hasMotion3D)
        XCTAssertEqual(try roundTrip(c), c)
        XCTAssertFalse(TickerTemplate.newsRed.config(text: "x").is3D)
    }
}
