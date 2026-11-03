import Foundation

/// Automatic highlights (0.58.0): moments marked during the event (⇧⌘H, the ★ button, the web
/// controller or MIDI) become one highlight video cut from the Program recording, each moment
/// with a pre-roll and post-roll, joined with short crossfades.

public enum HighlightFormat: String, Codable, Sendable, CaseIterable {
    /// Same picture as the recording (16:9).
    case landscape
    /// Centre crop to 9:16 for Reels / TikTok / Shorts.
    case vertical
}

public struct HighlightSettings: Codable, Equatable, Sendable {
    /// Seconds before each mark (the moment usually started before the operator pressed).
    public var preRoll: Double = 15
    /// Seconds after each mark.
    public var postRoll: Double = 10
    /// Crossfade between moments (0 = straight cut).
    public var crossfade: Double = 0.75
    /// Fade in from / out to black at the start and the end.
    public var fadeEnds: Bool = true
    public var format: HighlightFormat = .landscape
    /// Also save each moment as its own file.
    public var separateClips: Bool = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HighlightSettings()
        preRoll = (try? c.decodeIfPresent(Double.self, forKey: .preRoll)) ?? d.preRoll
        postRoll = (try? c.decodeIfPresent(Double.self, forKey: .postRoll)) ?? d.postRoll
        crossfade = (try? c.decodeIfPresent(Double.self, forKey: .crossfade)) ?? d.crossfade
        fadeEnds = (try? c.decodeIfPresent(Bool.self, forKey: .fadeEnds)) ?? d.fadeEnds
        format = (try? c.decodeIfPresent(HighlightFormat.self, forKey: .format)) ?? d.format
        separateClips = (try? c.decodeIfPresent(Bool.self, forKey: .separateClips)) ?? d.separateClips
    }

    public var clamped: HighlightSettings {
        var s = self
        s.preRoll = min(max(preRoll, 0), 120)
        s.postRoll = min(max(postRoll, 0), 120)
        s.crossfade = min(max(crossfade, 0), 2)
        return s
    }
}

/// A marked moment, as seconds into a recording.
public struct HighlightMark: Codable, Equatable, Sendable, Identifiable {
    public var id: String = UUID().uuidString
    public var offset: Double
    public var title: String
    /// Unticked moments are left out of the video.
    public var enabled: Bool = true
    public init(offset: Double, title: String = "", enabled: Bool = true) {
        self.offset = offset; self.title = title; self.enabled = enabled
    }
}

/// The marks of one recording, saved next to it as "<recording>.highlights.json" so the video can
/// still be made after the app was closed.
public struct HighlightSidecar: Codable, Equatable, Sendable {
    public var recordingStart: Date
    public var marks: [HighlightMark]
    public init(recordingStart: Date, marks: [HighlightMark] = []) { self.recordingStart = recordingStart; self.marks = marks }

    public static func url(for recording: URL) -> URL {
        recording.deletingPathExtension().appendingPathExtension("highlights.json")
    }
}

/// One piece of the highlight video: a range of the recording placed at `start` on the timeline.
public struct HighlightSegment: Equatable, Sendable {
    public var source: ClosedRange<Double>
    public var start: Double
    public var duration: Double { source.upperBound - source.lowerBound }
    public var end: Double { start + duration }
}

public enum HighlightPlan {
    /// Ranges in the recording: `preRoll` before and `postRoll` after each enabled mark, inside
    /// `0...duration`; overlapping or touching ranges are merged; ranges under 1 s are dropped.
    public static func ranges(_ marks: [HighlightMark], duration: Double, settings: HighlightSettings) -> [ClosedRange<Double>] {
        let s = settings.clamped
        let raw = marks.filter { $0.enabled && $0.offset >= 0 && $0.offset <= duration }
            .map(\.offset).sorted()
            .map { max(0, $0 - s.preRoll)...min(duration, $0 + s.postRoll) }
        var out: [ClosedRange<Double>] = []
        // Clips closer than a crossfade would overlap on the timeline: merge them too.
        let gap = s.crossfade
        for r in raw {
            if let last = out.last, r.lowerBound <= last.upperBound + gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out.filter { $0.upperBound - $0.lowerBound >= 1 }
    }

    /// Places the ranges one after another; each overlaps the previous one by the crossfade
    /// (shortened for very short clips so a fade never takes more than half a clip).
    public static func timeline(_ ranges: [ClosedRange<Double>], crossfade: Double) -> [HighlightSegment] {
        var out: [HighlightSegment] = []
        var t = 0.0
        for (i, r) in ranges.enumerated() {
            let seg = HighlightSegment(source: r, start: t)
            out.append(seg)
            let next = i + 1 < ranges.count ? ranges[i + 1].upperBound - ranges[i + 1].lowerBound : 0
            let fade = i + 1 < ranges.count ? transition(crossfade, seg.duration, next) : 0
            t = seg.end - fade
        }
        return out
    }

    /// The crossfade used between two clips of these lengths.
    public static func transition(_ crossfade: Double, _ a: Double, _ b: Double) -> Double {
        max(0, min(crossfade, a / 2, b / 2))
    }

    public static func totalDuration(_ segments: [HighlightSegment]) -> Double { segments.last?.end ?? 0 }

    /// Marks of a show (dates) as offsets into a recording that started at `recordingStart`.
    public static func marks(_ show: [ShowMark], recordingStart: Date) -> [HighlightMark] {
        show.filter { $0.kind == .highlight }.map {
            HighlightMark(offset: $0.date.timeIntervalSince(recordingStart), title: $0.title)
        }
    }
}
