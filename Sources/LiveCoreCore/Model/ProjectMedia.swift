import Foundation

/// Media files a project points at (0.80.0): find the ones that were moved or deleted before the
/// project opens, and point them at a new place (the Missing Files dialog).
extension ProjectDocument {
    /// The same project with every media reference passed through `f`.
    public func mapMedia(_ f: (ProjectMediaRef) -> ProjectMediaRef) -> ProjectDocument {
        var d = self
        func one(_ path: String, _ rel: String?) -> ProjectMediaRef { f(ProjectMediaRef(path: path, relativePath: rel)) }
        for i in d.inputs.indices {
            switch d.inputs[i].source {
            case let .videoFile(path, rel, loop):
                let m = one(path, rel)
                d.inputs[i].source = .videoFile(path: m.path, relativePath: m.relativePath, loop: loop)
            case let .image(path, rel):
                let m = one(path, rel)
                d.inputs[i].source = .image(path: m.path, relativePath: m.relativePath)
            case let .videoPlaylist(tracks, loop):
                d.inputs[i].source = .videoPlaylist(tracks: tracks.map(f), loop: loop)
            case var .slideshow(s) where s.folder == nil:
                s.images = s.images.map(f)
                d.inputs[i].source = .slideshow(s)
            case var .presentation(p):
                p.file = f(p.file)
                d.inputs[i].source = .presentation(p)
            default: break
            }
        }
        d.audio.music = d.audio.music?.map { m in var m = m; m.tracks = m.tracks.map(f); return m }
        return d
    }

    /// Saved paths of the media files found neither at their path nor next to the project folder.
    public func missingMedia(projectDirectory: String?, exists: (String) -> Bool) -> [String] {
        var missing: [String] = []
        _ = mapMedia { ref in
            let near = ref.relativePath.flatMap { r in projectDirectory.map { ProjectPaths.resolve(r, againstDirectory: $0) } }
            if !exists(ref.path), !(near.map(exists) ?? false), !missing.contains(ref.path) { missing.append(ref.path) }
            return ref
        }
        return missing
    }

    /// The same project with the files in `moves` (old path → new path) pointing at their new place.
    public func relinked(_ moves: [String: String]) -> ProjectDocument {
        moves.isEmpty ? self : mapMedia { ref in moves[ref.path].map { ProjectMediaRef(path: $0) } ?? ref }
    }
}

public enum MissingMedia {
    /// For each missing path, the first candidate file with the same name (case-insensitive).
    public static func matches(missing: [String], candidates: [String]) -> [String: String] {
        var byName: [String: String] = [:]
        for c in candidates { byName[fileName(c)] = byName[fileName(c)] ?? c }
        var out: [String: String] = [:]
        for m in missing { if let c = byName[fileName(m)] { out[m] = c } }
        return out
    }

    static func fileName(_ path: String) -> String { (path.split(separator: "/").last.map(String.init) ?? path).lowercased() }
}
