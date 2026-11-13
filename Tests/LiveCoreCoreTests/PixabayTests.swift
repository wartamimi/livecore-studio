import XCTest
@testable import LiveCoreServices
@testable import LiveCoreCore

final class PixabayTests: XCTestCase {
    func testSearchURL() {
        let u = Pixabay.searchURL(key: "abc", query: " wedding flowers ", kind: .photo, page: 2)!.absoluteString
        XCTAssertTrue(u.hasPrefix("https://pixabay.com/api/?"))
        XCTAssertTrue(u.contains("key=abc") && u.contains("q=wedding%20flowers") && u.contains("page=2") && u.contains("image_type=photo"))
        let v = Pixabay.searchURL(key: "abc", query: "sea", kind: .video)!.absoluteString
        XCTAssertTrue(v.hasPrefix("https://pixabay.com/api/videos/?"))
        XCTAssertFalse(v.contains("image_type"))
    }

    func testParseImages() throws {
        let json = #"{"total":5,"totalHits":2,"hits":[{"id":7,"tags":"rose, red","user":"ana","pageURL":"https://pixabay.com/photos/rose-7/","previewURL":"https://cdn.pixabay.com/p/7_150.jpg","webformatURL":"https://pixabay.com/get/7_640.jpg","largeImageURL":"https://pixabay.com/get/7_1280.png","imageWidth":4000,"imageHeight":3000},{"tags":"no id"}]}"#
        let p = try Pixabay.parse(Data(json.utf8), video: false)
        XCTAssertEqual(p.total, 2)
        XCTAssertEqual(p.hits.count, 1)
        XCTAssertEqual(p.hits[0].downloadURL.absoluteString, "https://pixabay.com/get/7_1280.png")
        XCTAssertEqual(p.hits[0].fileExtension, "png")
        XCTAssertEqual(Pixabay.fileName(for: p.hits[0]), "pixabay-image-7.png")
    }

    func testParseVideosPrefersUpTo1080p() throws {
        let json = #"{"totalHits":1,"hits":[{"id":9,"tags":"sea","user":"bo","duration":12,"videos":{"large":{"url":"https://cdn.pixabay.com/v/9_large.mp4","width":3840,"height":2160,"thumbnail":"https://cdn.pixabay.com/v/9_l.jpg"},"medium":{"url":"https://cdn.pixabay.com/v/9_medium.mp4","width":1920,"height":1080,"thumbnail":"https://cdn.pixabay.com/v/9_m.jpg"},"tiny":{"url":"https://cdn.pixabay.com/v/9_tiny.mp4","width":640,"height":360,"thumbnail":"https://cdn.pixabay.com/v/9_t.jpg"}}}]}"#
        let p = try Pixabay.parse(Data(json.utf8), video: true)
        XCTAssertEqual(p.hits.first?.downloadURL.absoluteString, "https://cdn.pixabay.com/v/9_medium.mp4")
        XCTAssertEqual(p.hits.first?.thumbnailURL?.absoluteString, "https://cdn.pixabay.com/v/9_t.jpg")
        XCTAssertEqual(p.hits.first?.duration, 12)
        XCTAssertThrowsError(try Pixabay.parse(Data("[]".utf8), video: true))
    }

    func testTailscaleHostsRefused() {
        XCTAssertFalse(RemoteAuth.hostAllowed("studio.tail1a2b.ts.net"))
    }
}
