import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.43.0: auto-framing maths and the client delivery package.
final class AIDeliveryTests: XCTestCase {
    func testAutoFrameRectAndTarget() {
        let s = PixelSize(width: 1920, height: 1080)
        let r = AutoFrame.rect(source: s, zoom: 2, cx: 0.5, cy: 0.5)
        XCTAssertEqual(r.width, 960); XCTAssertEqual(r.x, 480); XCTAssertEqual(r.y, 270)
        let edge = AutoFrame.rect(source: s, zoom: 2, cx: 0.99, cy: 0.0)
        XCTAssertEqual(edge.x, 960); XCTAssertEqual(edge.y, 0)
        XCTAssertNil(AutoFrame.target(faces: [], zoom: 2))
        let t = AutoFrame.target(faces: [(0.3, 0.4, 0.2), (0.7, 0.4, 0.2)], zoom: 1.5)!
        XCTAssertEqual(t.x, 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.y, 0.47, accuracy: 1e-9)   // headroom: aim below the eyes
        XCTAssertFalse(InputAI().isActive)
    }

    func testChaptersAndHighlights() {
        let start = Date(timeIntervalSince1970: 1000)
        let marks = [
            ShowMark(kind: .chapter, title: "Akad", date: start.addingTimeInterval(65)),
            ShowMark(kind: .chapter, title: "Doa", date: start.addingTimeInterval(70)),        // < 10 s: replaces Akad
            ShowMark(kind: .chapter, title: "Resepsi", date: start.addingTimeInterval(3725)),
            ShowMark(kind: .chapter, title: "Late", date: start.addingTimeInterval(99_999)),
            ShowMark(kind: .highlight, title: "", date: start.addingTimeInterval(100)),
            ShowMark(kind: .highlight, title: "", date: start.addingTimeInterval(110)),       // merges
            ShowMark(kind: .highlight, title: "", date: start.addingTimeInterval(5)),
        ]
        XCTAssertEqual(ClientPackage.chapters(marks, recordingStart: start, duration: 4000),
                       "0:00 Pembukaan\n1:05 Doa\n1:02:05 Resepsi\n")
        XCTAssertEqual(ClientPackage.highlightRanges(marks, recordingStart: start, duration: 4000),
                       [0...15, 80...120])
    }
}

final class SubtitleTextTests: XCTestCase {
    func testTailKeepsLastWords() {
        let t = "selamat datang di acara pernikahan kami semoga berkah untuk semua"
        XCTAssertEqual(SubtitleText.tail(t, maxChars: 20, lines: 2), ["kami semoga", "berkah untuk semua"])
        XCTAssertEqual(SubtitleText.tail("", maxChars: 20, lines: 2), [])
        let s = ProjectSource.subtitles(SubtitleStyle())
        XCTAssertEqual(try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(s)), s)
    }
}
