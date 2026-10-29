import Foundation
import XCTest
@testable import LiveCoreCore

/// 0.38.0: online radio (Radio Browser directory, ICY metadata, jitter buffer).
final class RadioTests: XCTestCase {
    func testSearchURLAsksForHTTPSWorkingStationsByPopularity() throws {
        let u = try XCTUnwrap(RadioBrowser.searchURL(server: "de1.api.radio-browser.info",
                                                    .init(name: " Prambors ", tag: "Pop", countryCode: "id", limit: 30)))
        let c = try XCTUnwrap(URLComponents(url: u, resolvingAgainstBaseURL: false))
        XCTAssertEqual(c.scheme, "https")
        XCTAssertEqual(c.path, "/json/stations/search")
        let q = Dictionary(uniqueKeysWithValues: (c.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["name"], "Prambors")
        XCTAssertEqual(q["tag"], "pop")
        XCTAssertEqual(q["countrycode"], "ID")
        XCTAssertEqual(q["is_https"], "true")
        XCTAssertEqual(q["hidebroken"], "true")
        XCTAssertEqual(q["order"], "clickcount")
        XCTAssertEqual(q["reverse"], "true")
        XCTAssertEqual(q["limit"], "60")
        let empty = try XCTUnwrap(RadioBrowser.searchURL(server: "x", .init()))
        XCTAssertFalse(empty.absoluteString.contains("name="))
        XCTAssertFalse(empty.absoluteString.contains("countrycode="))
    }

    func testDecodeKeepsOnlyPlayableStations() throws {
        let json = """
        [
          {"stationuuid":"a1","name":"Good MP3","url":"http://x/pls","url_resolved":"https://s.example.com/live.mp3","homepage":"https://h",
           "favicon":"","tags":"pop,jazz,news,talk","countrycode":"ID","codec":"MP3","bitrate":128,"hls":0,"lastcheckok":1,"clickcount":9},
          {"stationuuid":"a2","name":"HLS","url_resolved":"https://s.example.com/live.m3u8","codec":"AAC","bitrate":64,"hls":1,"lastcheckok":1},
          {"stationuuid":"a3","name":"Plain HTTP","url_resolved":"http://s.example.com/live","codec":"MP3","bitrate":128,"hls":0,"lastcheckok":1},
          {"stationuuid":"a4","name":"Ogg","url_resolved":"https://s.example.com/live.ogg","codec":"OGG","bitrate":96,"hls":0,"lastcheckok":1},
          {"stationuuid":"a5","name":"Broken","url_resolved":"https://s.example.com/b","codec":"MP3","hls":0,"lastcheckok":0},
          {"stationuuid":"a6","name":"HE-AAC","url_resolved":"https://s.example.com/aac","codec":"aac+","bitrate":48,"hls":0,"lastcheckok":1},
          {"stationuuid":"a1","name":"Duplicate","url_resolved":"https://s.example.com/live.mp3","codec":"MP3","hls":0,"lastcheckok":1},
          {"stationuuid":"a7","name":"Playlist","url_resolved":"https://s.example.com/listen.pls","codec":"MP3","hls":0,"lastcheckok":1},
          {"name":"No id","url_resolved":"https://s.example.com/x","codec":"MP3"}
        ]
        """
        let list = try RadioBrowser.decodeStations(Data(json.utf8))
        XCTAssertEqual(list.map(\.id), ["a1", "a6"])
        XCTAssertEqual(list[0].streamURL, "https://s.example.com/live.mp3")
        XCTAssertEqual(list[0].summary, "MP3 · 128 kbit/s · ID · pop, jazz, news")
        XCTAssertTrue(list[1].isAAC)
        XCTAssertEqual(try RadioBrowser.decodeStations(Data(json.utf8), limit: 1).count, 1)
        XCTAssertThrowsError(try RadioBrowser.decodeStations(Data("{}".utf8)))
    }

    func testClickURLOnlyForStationIDs() {
        XCTAssertEqual(RadioBrowser.clickURL(server: "de1.api.radio-browser.info", stationID: "9617a958-0601-11e8-ae97-52543be04c81")?.absoluteString,
                       "https://de1.api.radio-browser.info/json/url/9617a958-0601-11e8-ae97-52543be04c81")
        XCTAssertNil(RadioBrowser.clickURL(server: "x", stationID: "../../etc"))
        XCTAssertNil(RadioBrowser.clickURL(server: "x", stationID: ""))
    }

    func testICYMetadataIsStrippedAcrossChunks() {
        // 8 audio bytes, metadata block of 32 bytes, 8 audio bytes, empty block, 3 audio bytes.
        let text = Array("StreamTitle='Band - Song';".utf8)
        var block = text + [UInt8](repeating: 0, count: 32 - text.count)
        block.insert(2, at: 0)   // length byte: 2 × 16
        let stream: [UInt8] = Array(1...8) + block + Array(11...18) + [0] + [21, 22, 23]
        var reader = ICYMetadataReader(metaInt: 8)
        var audio = [UInt8](), titles = [String]()
        // Feed in awkward pieces so blocks straddle chunk boundaries.
        var i = 0
        for size in [3, 7, 1, 13, 5, 100] where i < stream.count {
            let piece = Array(stream[i..<min(i + size, stream.count)])
            i += piece.count
            let r = reader.feed(piece)
            audio += r.audio
            titles += r.titles
        }
        XCTAssertEqual(audio, Array(1...8) + Array(11...18) + [21, 22, 23])
        XCTAssertEqual(titles, ["Band - Song"])
        var plain = ICYMetadataReader(metaInt: 0)
        XCTAssertEqual(plain.feed([1, 2, 3]).audio, [1, 2, 3])
        XCTAssertEqual(ICYMetadataReader.title(in: Array("StreamTitle='';StreamUrl='';".utf8)), nil)
        XCTAssertEqual(ICYMetadataReader.title(in: [0x53] + Array("treamTitle='Caf\u{e9}';".data(using: .isoLatin1)!)), "Caf\u{e9}")
    }

    func testJitterBufferPrebuffersRebuffersAndDropsOldest() {
        var b = StreamAudioBuffer(capacity: 10, prebuffer: 4)
        var outL = [Float](repeating: 0, count: 10), outR = outL
        func push(_ values: [Float]) { values.withUnsafeBufferPointer { p in b.append(left: p.baseAddress!, right: p.baseAddress!, count: values.count) } }
        func pull(_ n: Int) -> [Float] {
            let got = outL.withUnsafeMutableBufferPointer { l in outR.withUnsafeMutableBufferPointer { r in b.read(left: l.baseAddress!, right: r.baseAddress!, count: n) } }
            return Array(outL[0..<got])
        }
        push([1, 2, 3])
        XCTAssertTrue(b.isBuffering)
        XCTAssertEqual(pull(2), [], "silent until the prebuffer is full")
        push([4])
        XCTAssertFalse(b.isBuffering)
        XCTAssertEqual(pull(3), [1, 2, 3])
        XCTAssertEqual(pull(5), [4])
        XCTAssertTrue(b.isBuffering, "ran dry: waits for the prebuffer again")
        XCTAssertEqual(b.underruns, 1)
        push([5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16])   // 12 frames into a 10-frame buffer
        XCTAssertEqual(b.queuedFrames, 10)
        XCTAssertEqual(b.droppedFrames, 2)
        XCTAssertEqual(pull(10), [7, 8, 9, 10, 11, 12, 13, 14, 15, 16])
        push([1, 2, 3, 4, 5, 6, 7, 8])
        push([9, 10, 11])                                   // wraps and drops the oldest one
        XCTAssertEqual(pull(10), [2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    }

    func testProjectKeepsRadiosAndDropsUnsafeOnes() throws {
        var doc = ProjectDocument()
        let ok = RadioStation(id: "a1", name: "Station", streamURL: "https://s.example.com/live.mp3", codec: "MP3", bitrate: 128)
        let unsafe = RadioStation(id: "a2", name: "Local", streamURL: "file:///etc/passwd", codec: "MP3")
        doc.audio.radios = [ProjectRadio(id: "r1", station: ok), ProjectRadio(id: "r2", station: unsafe)]
        let back = try JSONDecoder().decode(ProjectDocument.self, from: JSONEncoder().encode(doc)).sanitized()
        XCTAssertEqual(back.audio.radios?.map(\.id), ["r1"])
        XCTAssertEqual(back.audio.radios?.first?.station, ok)
        // Projects from before 0.38.0 have no radios.
        XCTAssertNil(ProjectDocument().sanitized().audio.radios)
    }
}
