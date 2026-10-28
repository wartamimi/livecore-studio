import Foundation

/// On-device AI per input (0.43.0): background removal without a green screen and auto-framing.
/// Runs on Apple Silicon only (Neural Engine); on Intel Macs it stays off so the frame rate holds.
public struct InputAI: Codable, Equatable, Sendable {
    public var removeBackground: Bool = false
    public var autoFrame: Bool = false
    /// How far auto-framing zooms in: 1.2 (wide) … 2.5 (tight).
    public var zoom: Double = 1.5
    public init(removeBackground: Bool = false, autoFrame: Bool = false, zoom: Double = 1.5) {
        self.removeBackground = removeBackground; self.autoFrame = autoFrame; self.zoom = zoom
    }
    public var isActive: Bool { removeBackground || autoFrame }
}

public enum AutoFrame {
    /// The `1/zoom` sized crop of a `source` frame centred on (cx, cy) in 0…1 (origin top left),
    /// kept inside the frame. Pixels, origin top left.
    public static func rect(source: PixelSize, zoom: Double, cx: Double, cy: Double)
        -> (x: Double, y: Double, width: Double, height: Double) {
        let z = min(max(zoom, 1), 4)
        let W = Double(source.width), H = Double(source.height)
        let w = W / z, h = H / z
        let x = min(max(cx * W - w / 2, 0), W - w)
        let y = min(max(cy * H - h / 2, 0), H - h)
        return (x, y, w, h)
    }

    /// Where to aim for faces given as (centerX, centerY, height) in 0…1, origin top left: the
    /// faces' middle, with the eyes a little above the centre of the shot (headroom).
    public static func target(faces: [(x: Double, y: Double, height: Double)], zoom: Double) -> (x: Double, y: Double)? {
        guard !faces.isEmpty else { return nil }
        let minX = faces.map(\.x).min()!, maxX = faces.map(\.x).max()!
        let cy = faces.map(\.y).reduce(0, +) / Double(faces.count)
        let h = faces.map(\.height).max()!
        return ((minX + maxX) / 2, min(max(cy + h * 0.35, 0), 1))
    }
}

/// A moment marked during the show: a chapter (rundown segment) or a highlight.
public struct ShowMark: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case chapter, highlight }
    public var kind: Kind
    public var title: String
    public var date: Date
    public init(kind: Kind, title: String, date: Date) { self.kind = kind; self.title = title; self.date = date }
}

/// The client delivery package made after the event (0.43.0): recordings, chapters, highlights.
public enum ClientPackage {
    /// YouTube-style chapter list ("0:00 Title" per line) relative to the recording start. YouTube
    /// needs the first chapter at 0:00 and chapters at least 10 s apart; marks before the start or
    /// after `duration` are dropped.
    public static func chapters(_ marks: [ShowMark], recordingStart: Date, duration: Double,
                                firstTitle: String = "Pembukaan") -> String {
        var list: [(Double, String)] = []
        for m in marks where m.kind == .chapter {
            let t = m.date.timeIntervalSince(recordingStart)
            guard t >= 0, t < duration else { continue }
            if let last = list.last, t - last.0 < 10 { list[list.count - 1] = (last.0, m.title); continue }
            list.append((t, m.title))
        }
        if list.first.map({ $0.0 > 0.5 }) ?? true { list.insert((0, firstTitle), at: 0) } else { list[0].0 = 0 }
        return list.map { "\(timestamp($0.0)) \($0.1)" }.joined(separator: "\n") + "\n"
    }

    public static func timestamp(_ t: Double) -> String {
        let s = Int(t.rounded(.down))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// Highlight clip ranges (seconds in the recording): `before` seconds before each mark and
    /// `after` after it, inside the recording; overlapping clips are merged.
    public static func highlightRanges(_ marks: [ShowMark], recordingStart: Date, duration: Double,
                                       before: Double = 20, after: Double = 10) -> [ClosedRange<Double>] {
        let raw = marks.filter { $0.kind == .highlight }
            .map { $0.date.timeIntervalSince(recordingStart) }
            .filter { $0 >= 0 && $0 <= duration }
            .sorted()
            .map { max(0, $0 - before)...min(duration, $0 + after) }
        var out: [ClosedRange<Double>] = []
        for r in raw {
            if let last = out.last, r.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out.filter { $0.upperBound - $0.lowerBound >= 1 }
    }
}

/// Live subtitles input (0.43.0): speech of the Program sound turned into captions.
public struct SubtitleStyle: Codable, Equatable, Sendable {
    public var locale: String = "id-ID"
    /// Apple's speech recognition on this Mac only; when the language has no on-device model the
    /// operator may allow Apple's servers (internet) instead.
    public var allowServer: Bool = false
    public var fontSize: Double = 44        // at 1080p
    public var maxLines: Int = 2
    public var boxOpacity: Double = 0.6
    /// Bottom margin, fraction of the output height.
    public var bottomMargin: Double = 0.08
    public init() {}
}

public enum SubtitleText {
    /// The last words of a running transcript that fit `maxChars` per line on `lines` lines,
    /// broken at spaces (a caption shows what is being said now, not the whole speech).
    public static func tail(_ transcript: String, maxChars: Int, lines: Int) -> [String] {
        let words = transcript.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        var out: [String] = []
        var line = ""
        for w in words.reversed() {
            let candidate = line.isEmpty ? w : w + " " + line
            if candidate.count <= maxChars || line.isEmpty {
                line = candidate
            } else {
                out.insert(line, at: 0)
                if out.count == lines { return out }
                line = w
            }
        }
        if !line.isEmpty { out.insert(line, at: 0) }
        return Array(out.suffix(lines))
    }
}
