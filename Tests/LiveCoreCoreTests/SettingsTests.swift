import XCTest
import Foundation
@testable import LiveCoreCore

final class SettingsTests: XCTestCase {
    func testDefaultSettingsAreValidAndCodable() throws {
        let s = ProductionSettings()
        XCTAssertEqual(s.validationErrors(), [])
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ProductionSettings.self, from: data), s)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).lowercased().contains("streamkey"), "key never serialized")
    }

    func testValidationCatchesBadValues() {
        var s = ProductionSettings()
        s.output = OutputFormat(size: PixelSize(width: 1281, height: 720), frameRate: 0)
        s.video.bitrateKbps = 10
        s.audio.bitrateKbps = 100
        XCTAssertEqual(s.validationErrors().count, 4)
    }

    func testFileNaming() {
        XCTAssertEqual(FileNaming.fileName(pattern: "LiveCore {date} {time}", year: 2026, month: 3, day: 7, hour: 9,
                                           minute: 5, second: 1, counter: 1, ext: "mp4"), "LiveCore 2026-03-07 09-05-01.mp4")
        XCTAssertEqual(FileNaming.fileName(pattern: "a/b:{n}", year: 2026, month: 1, day: 1, hour: 0, minute: 0,
                                           second: 0, counter: 3, ext: "mov"), "a-b-3.mov")
        XCTAssertEqual(FileNaming.fileName(pattern: ".hidden", year: 2026, month: 1, day: 1, hour: 0, minute: 0,
                                           second: 0, counter: 1, ext: "mp4"), "Recording.hidden.mp4")
    }
}
