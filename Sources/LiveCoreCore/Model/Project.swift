/// Saved production (a ".livecore" project file, JSON): inputs, scene layers, chroma keys,
/// overlays, transition, mixer settings and output settings. The stream key is never stored
/// here (it stays in the Keychain).
///
/// Core stays Foundation-free: this file only defines the Codable model and its consistency
/// rules; the app encodes it with JSONEncoder.
public struct ProjectDocument: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let fileExtension = "livecore"

    public var version: Int
    public var settings: ProductionSettings
    public var inputs: [ProjectInput]
    public var overlays: [ProjectOverlay]
    public var audio: ProjectAudio
    public var previewInput: InputID?
    public var programInput: InputID?
    /// Stinger transition clip and cut point (absent in projects from before 0.5.0).
    public var stinger: StingerConfig?
    /// The four extra outputs and the virtual camera's output (added in 0.22.0).
    public var outputs: OutputRouting?
    /// Inputs recorded to their own files by the MultiCorder (added in 0.32.0).
    public var multiCorder: MultiCorderConfig?
    /// Names given to colour groups in the inputs panel, by colour (added in 0.33.0).
    public var groupNames: [String: String]?

    public init(version: Int = ProjectDocument.currentVersion, settings: ProductionSettings = ProductionSettings(),
                inputs: [ProjectInput] = [], overlays: [ProjectOverlay] = [], audio: ProjectAudio = ProjectAudio(),
                previewInput: InputID? = nil, programInput: InputID? = nil) {
        self.version = version; self.settings = settings; self.inputs = inputs; self.overlays = overlays
        self.audio = audio; self.previewInput = previewInput; self.programInput = programInput
    }

    /// Problems that would leave dangling references. Empty means the document is consistent.
    public func validationIssues() -> [String] {
        var issues: [String] = []
        if version > Self.currentVersion {
            issues.append("Project was saved by a newer LiveCore Studio (format \(version)); some settings may be ignored.")
        }
        var seen = Set<InputID>()
        for i in inputs {
            if !seen.insert(i.id).inserted { issues.append("Duplicate input id \(i.id).") }
        }
        for i in inputs {
            for l in i.layers where l.source != i.id && !seen.contains(l.source) {
                issues.append("Input \"\(i.name)\" has a layer pointing at a missing input.")
            }
        }
        for o in overlays {
            if let s = o.source, !seen.contains(s) { issues.append("Overlay \(o.index) points at a missing input.") }
        }
        if let p = previewInput, !seen.contains(p) { issues.append("Preview points at a missing input.") }
        if let p = programInput, !seen.contains(p) { issues.append("Program points at a missing input.") }
        if let s = stinger?.source, !seen.contains(s) { issues.append("Stinger points at a missing input.") }
        return issues
    }

    /// Copy with dangling references removed, duplicate inputs dropped (first wins), every input's
    /// first layer being the input itself, and overlay indices restricted to 1...4.
    public func sanitized() -> ProjectDocument {
        var doc = self
        var seen = Set<InputID>()
        doc.inputs = inputs.filter { seen.insert($0.id).inserted }
        for k in doc.inputs.indices {
            let id = doc.inputs[k].id
            var layers = doc.inputs[k].layers.filter { $0.source == id || seen.contains($0.source) }
            if layers.first?.source != id {
                layers.removeAll { $0.source == id }
                layers.insert(Layer(source: id), at: 0)
            }
            doc.inputs[k].layers = layers
        }
        var indices = Set<Int>()
        doc.overlays = overlays.filter { (1...4).contains($0.index) && indices.insert($0.index).inserted }
        for k in doc.overlays.indices {
            if let s = doc.overlays[k].source, !seen.contains(s) { doc.overlays[k].source = nil }
        }
        if let p = previewInput, !seen.contains(p) { doc.previewInput = nil }
        if let p = programInput, !seen.contains(p) { doc.programInput = nil }
        if let s = doc.stinger?.source, !seen.contains(s) { doc.stinger?.source = nil }
        doc.outputs = outputs?.normalized(existing: seen)
        doc.multiCorder = multiCorder?.keeping(existing: seen)
        return doc
    }
}

public struct ProjectInput: Codable, Equatable, Sendable {
    public var id: InputID
    public var name: String
    public var source: ProjectSource
    /// Scene layers; layer 0 is the input itself.
    public var layers: [Layer]
    public var chromaKey: ChromaKey?
    /// Video inputs: "off", "playPause" or "restartPause" (absent before 0.8.0 = off).
    public var autoPlay: String?
    /// Protected against closing / editing in the UI (since 0.14.0; absent = unlocked).
    public var locked: Bool?
    /// Camera / capture card format and options (since 0.15.0; absent = automatic).
    public var capture: CaptureConfig?
    /// Colour correction and flips (since 0.16.0; absent = unchanged).
    public var adjust: InputAdjust?
    /// Colour label / group in the inputs panel, and a minimized tile (since 0.33.0).
    public var colorTag: InputColorTag?
    public var minimized: Bool?

    public init(id: InputID, name: String, source: ProjectSource, layers: [Layer] = [], chromaKey: ChromaKey? = nil) {
        self.id = id; self.name = name; self.source = source
        self.layers = layers.isEmpty ? [Layer(source: id)] : layers
        self.chromaKey = chromaKey
    }
}

public struct ProjectColor: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
}

public struct ProjectTitleStyle: Codable, Equatable, Sendable {
    public var title: String
    public var subtitle: String
    public var showBar: Bool
    public var textColor: ProjectColor
    public var barColor: ProjectColor
    // Added in 0.3.0 (optional so 0.2.0 projects still decode).
    public var titleSize: Double?
    public var subtitleSize: Double?
    public var layout: String?
    /// Template and advanced settings (0.34.0). nil = the 0.3.0 lower-third strip above.
    public var design: TitleDesign?
    public init(title: String, subtitle: String, showBar: Bool = true,
                textColor: ProjectColor = ProjectColor(r: 1, g: 1, b: 1),
                barColor: ProjectColor = ProjectColor(r: 0.05, g: 0.27, b: 0.62, a: 0.88)) {
        self.title = title; self.subtitle = subtitle; self.showBar = showBar
        self.textColor = textColor; self.barColor = barColor
    }
}

/// What an input is made of. Media is referenced by absolute path plus the path relative to the
/// project file, so a project folder that is moved or copied to another Mac still resolves.
public enum ProjectSource: Codable, Equatable, Sendable {
    case camera(uniqueID: String, deviceName: String)
    case videoFile(path: String, relativePath: String?, loop: Bool)
    case image(path: String, relativePath: String?)
    case color(ProjectColor)
    case title(ProjectTitleStyle)
    /// Web page rendered offscreen (since 0.6.0).
    case browser(ProjectBrowser)
    /// Clock / countdown / count-up generator (since 0.6.0).
    case timer(TimerConfig, ProjectColor?)
    /// Several video clips played in order (since 0.8.0).
    case videoPlaylist(tracks: [ProjectMediaRef], loop: Bool)
    /// Window or display capture with optional app/system audio (since 0.10.0).
    case screen(ProjectScreenCapture)
    /// Lottie animation (0.13.0–0.14.0). No longer supported: kept so such projects still open
    /// (the input is skipped with a warning).
    case lottie(path: String, relativePath: String?, loop: Bool)
    /// SMPTE-style colour bars generator (since 0.15.0).
    case colorBars
    /// Empty transparent canvas whose content is its scene layers (since 0.15.0).
    case scene
    /// Scrolling text band (since 0.17.0).
    case ticker(TickerConfig)
    /// Photo slideshow (since 0.17.0).
    case slideshow(ProjectSlideshow)
    /// NDI® source from the network (since 0.29.0).
    case ndi(ProjectNDI)
}

public struct ProjectBrowser: Codable, Equatable, Sendable {
    public var url: String
    public var width: Int
    public var height: Int
    public var fps: Int
    public var transparent: Bool
    public init(url: String, width: Int = 1920, height: Int = 1080, fps: Int = 15, transparent: Bool = true) {
        self.url = url; self.width = width; self.height = height; self.fps = fps; self.transparent = transparent
    }
}

public struct ProjectOverlay: Codable, Equatable, Sendable {
    public var index: Int
    public var source: InputID?
    public var preset: LayoutPreset
    public var fadeDuration: Double
    /// In / out animation (since 0.20.0; nil = fade).
    public var animation: OverlayAnimation?
    public init(index: Int, source: InputID?, preset: LayoutPreset, fadeDuration: Double = 0.5, animation: OverlayAnimation? = nil) {
        self.index = index; self.source = source; self.preset = preset; self.fadeDuration = fadeDuration; self.animation = animation
    }
}

/// Mixer state. Channels are matched on load by `deviceUniqueID` (audio devices) or by the
/// owning video-file input (`inputID`).
public struct ProjectAudio: Codable, Equatable, Sendable {
    public var masterFaderDB: Float = 0
    public var limiterEnabled = true
    public var monitorVolume: Float = 1
    public var syncOffsetMs: Double = 0
    public var channels: [ProjectAudioChannel] = []
    /// Aux buses A and B (absent in projects from before 0.5.0).
    public var aux: [ProjectAuxBus]?
    /// Music players (absent in projects from before 0.7.0). Their mixer settings are in `channel`.
    public var music: [ProjectMusic]?
    /// Test tone generators (since 0.16.0). Their mixer settings are in `channel`.
    public var tones: [ProjectTone]?
    public init() {}
}

public struct ProjectAudioChannel: Codable, Equatable, Sendable {
    public var deviceUniqueID: String?
    public var inputID: InputID?
    public var name: String
    public var faderDB: Float = 0
    public var gainDB: Float = 0
    public var pan: Float = 0
    public var muted = false
    public var toProgram = true
    public var toBusA: Bool?
    public var toBusB: Bool?
    public var compressorEnabled = false
    public var compThresholdDB: Float = -18
    public var compRatio: Float = 3
    public var gateEnabled = false
    public var gateThresholdDB: Float = -50
    /// Added in 0.3.0 (optional so 0.2.0 projects still decode).
    public var eq: ProjectEQ?
    /// Audio follow video: the input this channel follows (added in 0.10.0).
    public var afvInput: InputID?
    /// Added in 0.15.0 (audio properties); absent = defaults.
    public var gateRangeDB: Float?
    public var compMakeupDB: Float?
    public var compAttackMs: Float?
    public var compReleaseMs: Float?
    public var channelMode: Int?
    public var invertPhase: Bool?
    public var delayMs: Float?
    /// Locked against closing from the mixer (since 0.21.0).
    public var locked: Bool?
    public init(deviceUniqueID: String? = nil, inputID: InputID? = nil, name: String) {
        self.deviceUniqueID = deviceUniqueID; self.inputID = inputID; self.name = name
    }
}

/// Relative-path helper for media references (pure string logic on "/"-separated POSIX paths).
public enum ProjectPaths {
    /// Path of `file` relative to directory `base` ("../Media/clip.mov"), or nil if either is not absolute.
    public static func relative(file: String, toDirectory base: String) -> String? {
        guard file.hasPrefix("/"), base.hasPrefix("/") else { return nil }
        let f = file.split(separator: "/", omittingEmptySubsequences: true)
        let b = base.split(separator: "/", omittingEmptySubsequences: true)
        var common = 0
        while common < f.count - 1 && common < b.count && f[common] == b[common] { common += 1 }
        let ups = Array(repeating: "..", count: b.count - common)
        return (ups + f[common...].map(String.init)).joined(separator: "/")
    }

    /// Resolves a relative path against directory `base`, normalising "." and "..".
    public static func resolve(_ relative: String, againstDirectory base: String) -> String {
        if relative.hasPrefix("/") { return relative }
        var parts = base.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for p in relative.split(separator: "/", omittingEmptySubsequences: true) {
            if p == "." { continue }
            if p == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(String(p)) }
        }
        return "/" + parts.joined(separator: "/")
    }
}

public struct ProjectEQ: Codable, Equatable, Sendable {
    public var highPassEnabled = false
    public var highPassHz: Float = 80
    public var eqEnabled = false
    public var lowDB: Float = 0
    public var midDB: Float = 0
    public var midHz: Float = 1000
    public var highDB: Float = 0
    public init() {}
}

/// An aux bus (A or B): its level and the output device it plays on (nil = not sent anywhere,
/// metering only). Devices are matched by Core Audio UID.
public struct ProjectAuxBus: Codable, Equatable, Sendable {
    public var faderDB: Float = 0
    public var muted = false
    public var outputDeviceUID: String?
    public init(faderDB: Float = 0, muted: Bool = false, outputDeviceUID: String? = nil) {
        self.faderDB = faderDB; self.muted = muted; self.outputDeviceUID = outputDeviceUID
    }
    private enum CodingKeys: String, CodingKey { case faderDB, muted, outputDeviceUID }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        faderDB = try c.decodeIfPresent(Float.self, forKey: .faderDB) ?? 0
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        outputDeviceUID = try c.decodeIfPresent(String.self, forKey: .outputDeviceUID)
    }
}

/// A media file reference: absolute path plus the path relative to the project file.
public struct ProjectMediaRef: Codable, Equatable, Sendable {
    public var path: String
    public var relativePath: String?
    public init(path: String, relativePath: String? = nil) { self.path = path; self.relativePath = relativePath }
}

/// Music input: playlist and options, with the settings of its mixer channel.
public struct ProjectTone: Codable, Equatable, Sendable {
    public var id: String
    public var frequency: Double
    public var levelDB: Double
    public var channel: ProjectAudioChannel?
    public init(id: String, frequency: Double = 1000, levelDB: Double = -18, channel: ProjectAudioChannel? = nil) {
        self.id = id; self.frequency = frequency; self.levelDB = levelDB; self.channel = channel
    }
}

public struct ProjectMusic: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var tracks: [ProjectMediaRef]
    public var loop: Bool
    public var shuffle: Bool
    public var channel: ProjectAudioChannel?
    /// Seconds of fade-out at the end and fade-in at the start of each song (since 0.20.0; nil = 0).
    public var fadeSeconds: Double?
    /// Repeat One (since 0.27.0; nil = off).
    public var repeatOne: Bool?
    public init(id: String, name: String, tracks: [ProjectMediaRef], loop: Bool = true, shuffle: Bool = false,
                channel: ProjectAudioChannel? = nil, fadeSeconds: Double? = nil) {
        self.id = id; self.name = name; self.tracks = tracks; self.loop = loop; self.shuffle = shuffle; self.channel = channel
        self.fadeSeconds = fadeSeconds
    }
}
