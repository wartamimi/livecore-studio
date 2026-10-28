/// Starting projects for common events (opened from the welcome screen or File › New from
/// Template): the connected cameras and microphones, titles with the right templates on the
/// overlay numbers, and mixer settings (music ducked under the MC).
public enum ProjectTemplate: String, CaseIterable, Sendable {
    /// 2–3 cameras, music, couple's names lower third, opening title.
    case wedding
    /// Camera, speaker lower third, countdown, slide frame.
    case seminar
    /// Camera in a frame, name lower third, clock (hybrid meetings, webinars).
    case meeting

    public struct Device: Equatable, Sendable {
        public var uniqueID: String
        public var name: String
        public init(uniqueID: String, name: String) { self.uniqueID = uniqueID; self.name = name }
    }

    /// Display texts (the UI passes them in the operator's language).
    public struct Texts: Sendable {
        public var camera = "Camera"
        public var music = "Music"
        public var coupleNames = "Bride & Groom"
        public var weddingDate = "Wedding Day"
        public var welcome = "Welcome"
        public var speaker = "Speaker Name"
        public var speakerRole = "Title / Organisation"
        public var startingSoon = "Starting soon"
        public var eventTitle = "Event Title"
        public var guest = "Guest Name"
        public init() {}
    }

    public static let maxCameras = 3

    public func document(cameras: [Device], microphones: [Device], texts t: Texts = Texts(),
                         settings: ProductionSettings = ProductionSettings()) -> ProjectDocument {
        var doc = ProjectDocument(settings: settings)
        var n = 0
        func id(_ prefix: String) -> InputID { n += 1; return InputID("tpl-\(prefix)-\(n)") }
        func title(_ template: TitleTemplate, _ title: String, _ subtitle: String, name: String) -> ProjectInput {
            var style = ProjectTitleStyle(title: title, subtitle: subtitle)
            style.design = template.defaultDesign
            return ProjectInput(id: id("title"), name: name, source: .title(style))
        }

        let camLimit = self == .wedding ? Self.maxCameras : (self == .seminar ? 2 : 1)
        var camIDs: [InputID] = []
        for (i, c) in cameras.prefix(camLimit).enumerated() {
            let cid = id("cam")
            camIDs.append(cid)
            doc.inputs.append(ProjectInput(id: cid, name: cameras.count > 1 ? "\(t.camera) \(i + 1)" : c.name,
                                           source: .camera(uniqueID: c.uniqueID, deviceName: c.name)))
        }

        var overlayInputs: [InputID] = []
        switch self {
        case .wedding:
            let names = title(.modernGlass, t.coupleNames, t.weddingDate, name: t.coupleNames)
            let opening = title(.fullScreenTitle, t.welcome, t.coupleNames, name: t.welcome)
            doc.inputs += [names, opening]
            overlayInputs = [names.id, opening.id]
            var music = ProjectMusic(id: "tpl-music", name: t.music, tracks: [], loop: true, fadeSeconds: 3)
            var ch = ProjectAudioChannel(name: t.music)
            ch.faderDB = -6
            ch.duckTarget = true
            music.channel = ch
            doc.audio.music = [music]
        case .seminar:
            let speaker = title(.classicStrap, t.speaker, t.speakerRole, name: t.speaker)
            let event = title(.chapterCard, t.eventTitle, "", name: t.eventTitle)
            let countdown = ProjectInput(id: id("timer"), name: t.startingSoon,
                                         source: .timer(TimerConfig(mode: .countdown, durationSeconds: 600, label: t.startingSoon), nil))
            var frame = FrameTemplate.broadcast.defaultDesign
            frame.title = t.speaker
            frame.subtitle = t.speakerRole
            let framed = ProjectInput(id: id("frame"), name: "Frame", source: .frame(frame))
            doc.inputs += [speaker, event, countdown, framed]
            overlayInputs = [speaker.id, event.id]
        case .meeting:
            var frame = FrameTemplate.rounded.defaultDesign
            frame.title = t.guest
            frame.subtitle = t.speakerRole
            let framed = ProjectInput(id: id("frame"), name: "Frame", source: .frame(frame))
            let name = title(.pill, t.guest, t.speakerRole, name: t.guest)
            let clock = ProjectInput(id: id("timer"), name: "Clock", source: .timer(TimerConfig(mode: .clock, showSeconds: false), nil))
            doc.inputs += [framed, name, clock]
            overlayInputs = [name.id]
        }

        doc.overlays = overlayInputs.enumerated().map { ProjectOverlay(index: $0.offset + 1, source: $0.element, preset: .fullScreen) }
        for mic in microphones.prefix(2) {
            var ch = ProjectAudioChannel(deviceUniqueID: mic.uniqueID, name: mic.name)
            ch.duckTrigger = self == .wedding ? true : nil
            ch.applySpeechDefaults()
            doc.audio.channels.append(ch)
        }
        if self == .wedding {
            var d = DuckingSettings()
            d.enabled = !microphones.isEmpty
            doc.audio.ducking = d
        }
        doc.programInput = camIDs.first ?? doc.inputs.first?.id
        doc.previewInput = camIDs.dropFirst().first ?? doc.inputs.first { $0.id != doc.programInput }?.id
        return doc
    }
}

extension ProjectAudioChannel {
    /// Speech microphones: 80 Hz high-pass and a gentle compressor.
    mutating func applySpeechDefaults() {
        var eq = ProjectEQ()
        eq.highPassEnabled = true
        eq.highPassHz = 80
        self.eq = eq
        compressorEnabled = true
        compThresholdDB = -20
        compRatio = 3
    }
}
