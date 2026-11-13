import Foundation

/// Event rundown (0.42.0): the running order of a show (akad, sambutan, resepsi …). Going to a
/// segment takes its input to Program, puts its title on an overlay channel and starts its music.
public struct Rundown: Codable, Equatable, Sendable {
    public var segments: [RundownSegment]
    public init(segments: [RundownSegment] = []) { self.segments = segments }
}

public struct RundownSegment: Codable, Equatable, Identifiable, Sendable {
    public enum Transition: String, Codable, Sendable, CaseIterable { case cut, auto }
    public enum Music: String, Codable, Sendable, CaseIterable {
        case keep    // leave the music as it is
        case play    // start `musicID` (other music stops)
        case stop    // stop all music the rundown started
    }
    public var id: String
    public var title: String
    public var notes: String
    /// Shown on Program when the segment starts (nil = keep the current shot).
    public var input: InputID?
    public var transition: Transition
    /// Title shown on overlay `overlayIndex` (1–4) during the segment.
    public var titleInput: InputID?
    public var overlayIndex: Int
    public var music: Music
    public var musicID: String?
    /// Planned length in minutes (0 = open-ended); with `autoNext` the next segment starts by itself.
    public var minutes: Double
    public var autoNext: Bool

    public init(id: String = UUID().uuidString, title: String, notes: String = "", input: InputID? = nil,
                transition: Transition = .auto, titleInput: InputID? = nil, overlayIndex: Int = 1,
                music: Music = .keep, musicID: String? = nil, minutes: Double = 0, autoNext: Bool = false) {
        self.id = id; self.title = title; self.notes = notes; self.input = input; self.transition = transition
        self.titleInput = titleInput; self.overlayIndex = overlayIndex; self.music = music; self.musicID = musicID
        self.minutes = minutes; self.autoNext = autoNext
    }
}

/// What the app does when a segment starts.
public enum RundownAction: Equatable, Sendable {
    case program(InputID, auto: Bool)
    case overlayOff(Int)
    case overlayOn(Int, InputID)
    case musicStop(String)
    case musicPlay(String)
}

public extension Rundown {
    /// Actions to go from `previous` (nil = show start) to segment `next`. Titles of the previous
    /// segment go off unless the same title stays on the same channel; music the previous
    /// segment started stops when the next one plays other music or says stop.
    static func actions(from previous: RundownSegment?, to next: RundownSegment) -> [RundownAction] {
        var out: [RundownAction] = []
        if let p = previous, let t = p.titleInput, !(next.titleInput == t && next.overlayIndex == p.overlayIndex) {
            out.append(.overlayOff(p.overlayIndex))
        }
        if let i = next.input { out.append(.program(i, auto: next.transition == .auto)) }
        if let t = next.titleInput, !(previous?.titleInput == t && previous?.overlayIndex == next.overlayIndex) {
            out.append(.overlayOn(min(max(next.overlayIndex, 1), 4), t))
        }
        switch next.music {
        case .keep: break
        case .stop:
            if let m = previous?.musicID ?? next.musicID { out.append(.musicStop(m)) }
        case .play:
            if let m = previous?.musicID, m != next.musicID, previous?.music == .play { out.append(.musicStop(m)) }
            if let m = next.musicID { out.append(.musicPlay(m)) }
        }
        return out
    }

    /// Seconds left in a segment that started `elapsed` seconds ago (nil when open-ended).
    static func remaining(_ s: RundownSegment, elapsed: Double) -> Double? {
        s.minutes > 0 ? s.minutes * 60 - elapsed : nil
    }

    /// Starting points for common events (titles only; the operator picks inputs, titles and music).
    static func template(_ name: String) -> Rundown {
        let titles: [(String, Double)]
        switch name {
        case "wedding":
            titles = [("Pembukaan", 5), ("Akad nikah", 20), ("Doa", 5), ("Sambutan keluarga", 10),
                      ("Resepsi", 60), ("Sesi foto", 20), ("Penutup", 5)]
        case "seminar":
            titles = [("Pembukaan", 5), ("Sambutan", 10), ("Materi 1", 30), ("Materi 2", 30),
                      ("Tanya jawab", 20), ("Penutup", 5)]
        default:
            titles = [("Segmen 1", 0)]
        }
        return Rundown(segments: titles.map { RundownSegment(title: $0.0, minutes: $0.1) })
    }
}
