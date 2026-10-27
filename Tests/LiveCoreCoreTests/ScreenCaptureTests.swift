import Foundation
import XCTest
@testable import LiveCoreCore

final class ScreenCaptureTests: XCTestCase {
    let zoomMain = WindowCandidate(windowID: 10, bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Meeting")
    let zoomHome = WindowCandidate(windowID: 11, bundleID: "us.zoom.xos", appName: "zoom.us", title: "Zoom Workplace")
    let teams = WindowCandidate(windowID: 20, bundleID: "com.microsoft.teams2", appName: "Microsoft Teams", title: "Standup | Microsoft Teams")
    let us = WindowCandidate(windowID: 30, bundleID: "com.livecore.studio", appName: "LiveCore Studio", title: "LiveCore Studio")
    let untitled = WindowCandidate(windowID: 40, bundleID: "com.apple.dock", appName: "Dock", title: "")

    func saved(_ title: String, app: String = "us.zoom.xos") -> ProjectScreenCapture {
        ProjectScreenCapture(target: .window, bundleID: app, appName: "zoom.us", windowTitle: title)
    }

    func testExactTitleWins() {
        XCTAssertEqual(WindowMatcher.find(saved("Zoom Meeting"), in: [zoomHome, zoomMain, teams]), zoomMain)
    }

    func testTitleThatChangedSlightlyStillMatches() {
        let s = saved("Standup", app: "com.microsoft.teams2")
        XCTAssertEqual(WindowMatcher.find(s, in: [teams, zoomMain]), teams)
    }

    func testOnlyWindowOfTheAppIsUsedWhenTitleIsGone() {
        XCTAssertEqual(WindowMatcher.find(saved("Old meeting name"), in: [zoomMain, teams]), zoomMain)
        XCTAssertNil(WindowMatcher.find(saved("Old meeting name"), in: [zoomMain, zoomHome]), "ambiguous: do not guess")
        XCTAssertNil(WindowMatcher.find(saved("Zoom Meeting"), in: [teams]), "app not running")
    }

    func testPickerHidesOwnAndUntitledWindows() {
        let list = WindowMatcher.pickerList([us, teams, untitled, zoomMain], ownBundleID: "com.livecore.studio")
        XCTAssertEqual(list, [teams, zoomMain])
    }

    func testProjectRoundTripAndFPSClamp() throws {
        let c = ProjectScreenCapture(target: .display, displayID: 2, captureAudio: false, fps: 30)
        let src = ProjectSource.screen(c)
        XCTAssertEqual(try JSONDecoder().decode(ProjectSource.self, from: JSONEncoder().encode(src)), src)
        XCTAssertEqual(ProjectScreenCapture.clampFPS(0), 1)
        XCTAssertEqual(ProjectScreenCapture.clampFPS(240), 60)
        XCTAssertEqual(saved("Zoom Meeting").displayName, "zoom.us – Zoom Meeting")
    }
}
