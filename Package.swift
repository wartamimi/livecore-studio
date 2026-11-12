// swift-tools-version:5.9
// LiveCore Studio — Swift Package manifest.
//
// Targets:
//   CAtomics          C11 atomics shim (lock-free primitives for real-time threads). Portable.
//   CObjCSupport      Objective-C @try/@catch shim so a misbehaving capture driver cannot crash the app.
//   CDeckLink         Blackmagic DeckLink capture: DeckLink API loaded from the installed Desktop Video
//                     driver at run time; vendored SDK 12.0 interface headers (Blackmagic permissive licence).
//   CVST3             VST 3 effect host (C++) on Steinberg's MIT-licensed VST 3 pluginterfaces (vendored).
//   CVST3TestPlugin   A tiny VST 3 gain effect, built only as the CI test plug-in (LCTestGainVST3).
//   CNDI              NDI® output: loads the installed NDI runtime with dlopen; vendored MIT SDK headers.
//   LiveCoreCore      Platform-independent logic: switcher state, transitions, layout math,
//                     audio DSP, FLV/AMF0/RTMP protocol (sans-IO). Builds & tests on Linux + macOS.
//   LiveCoreRemote    Web Controller HTTP server (POSIX sockets). Builds & tests on Linux + macOS.
//   LiveCoreServices  Autosave / crash recovery, file log and diagnostics export (Foundation). Linux + macOS.
//   LiveCoreEngine    macOS-only engines: AVFoundation capture, Metal compositor, Core Audio mixer,
//                     VideoToolbox/AAC encoders, RTMP transport (Network.framework), AVAssetWriter.
//   LiveCoreUI        SwiftUI operator interface (macOS) + localisation resources (en, id).
//   LiveCoreStudio    App entry point (App/). On other platforms it prints a notice and exits.
//   livecore-ndi-check     CI check: an NDI receiver finds a LiveCore-style NDI source and reads a frame.
//   livecore-iso-check     CI check: Program + MultiCorder ISO recorders write two playable files.
//   livecore-replay-check  CI check: the instant-replay buffer records, cuts a clip and the Replay input plays it.
//   livecore-title-check   CI check: every Title Designer template renders; writes a contact sheet.
//   livecore-srt-input-check  Dev check: receives SRT (listener/caller) through SRTInputLink and demuxes it.
//   livecore-plugin-check  CI check: Audio Unit + VST 3 hosting (scan, load, process, parameters, state).
//   livecore-rtmp-push  CLI that pushes H.264/AAC elementary streams through the LiveCoreCore RTMP
//                     client (used for protocol validation against a real RTMP server).
import PackageDescription

let package = Package(
    name: "LiveCoreStudio",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "LiveCoreStudio", targets: ["LiveCoreStudio"]),
        .executable(name: "livecore-rtmp-push", targets: ["livecore-rtmp-push"]),
        .library(name: "LiveCoreCore", targets: ["LiveCoreCore"]),
        .library(name: "LiveCoreEngine", targets: ["LiveCoreEngine"]),
        .library(name: "LiveCoreUI", targets: ["LiveCoreUI"]),
        .library(name: "LCTestGainVST3", type: .dynamic, targets: ["CVST3TestPlugin"]),
    ],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "CObjCSupport"),   // NSException guard for capture-driver calls (Apple only)
        .target(name: "CNDI", exclude: ["README.md"]),   // NDI runtime loader (dlopen; Apple only)
        .target(name: "CVST3", exclude: ["README.md", "sdk/pluginterfaces/LICENSE.txt", "sdk/pluginterfaces/README.md"],
                cxxSettings: [.headerSearchPath("sdk")],
                linkerSettings: [.linkedFramework("CoreFoundation", .when(platforms: [.macOS]))]),
        .target(name: "CVST3TestPlugin", cxxSettings: [.headerSearchPath("../CVST3/sdk")],
                linkerSettings: [.linkedFramework("CoreFoundation", .when(platforms: [.macOS]))]),
        .target(name: "CDeckLink", exclude: ["README.md", "decklink"]),   // DeckLink API via Desktop Video (Apple only)
        .target(name: "LiveCoreCore", dependencies: ["CAtomics"]),
        .target(name: "LiveCoreRemote", dependencies: ["LiveCoreCore"]),
        .target(name: "LiveCoreServices", dependencies: ["LiveCoreCore"]),
        .target(name: "LiveCoreEngine", dependencies: [
            "LiveCoreCore", "LiveCoreServices", "CAtomics", "CObjCSupport", "CNDI", "CDeckLink", "CVST3",
        ]),
        .target(
            name: "LiveCoreUI",
            dependencies: ["LiveCoreEngine", "LiveCoreCore", "LiveCoreRemote", "LiveCoreServices"],
            resources: [.process("Resources"), .copy("Flags")]
        ),
        .executableTarget(name: "LiveCoreStudio", dependencies: ["LiveCoreUI"], path: "App"),
        .executableTarget(name: "livecore-rtmp-push", dependencies: ["LiveCoreCore"]),
        .executableTarget(name: "livecore-transition-dump", dependencies: ["LiveCoreCore"]),
        .executableTarget(name: "livecore-ndi-check", dependencies: ["CNDI", "LiveCoreCore", "LiveCoreEngine"]),
        .executableTarget(name: "livecore-iso-check", dependencies: ["LiveCoreCore", "LiveCoreEngine"]),
        .executableTarget(name: "livecore-replay-check", dependencies: ["LiveCoreCore", "LiveCoreEngine"]),
        .executableTarget(name: "livecore-title-check", dependencies: ["LiveCoreCore", "LiveCoreEngine", "LiveCoreServices"]),
        .executableTarget(name: "livecore-plugin-check", dependencies: ["LiveCoreCore", "LiveCoreEngine", "CVST3"]),
        .executableTarget(name: "livecore-soak-check", dependencies: ["LiveCoreCore", "LiveCoreEngine"]),
        .executableTarget(name: "livecore-radio-check", dependencies: ["LiveCoreCore", "LiveCoreEngine"]),
        .executableTarget(name: "livecore-srt-input-check", dependencies: ["LiveCoreCore", "LiveCoreEngine"]),
        .testTarget(name: "LiveCoreCoreTests", dependencies: ["LiveCoreCore", "LiveCoreRemote", "LiveCoreServices"]),
    ],
    cxxLanguageStandard: .gnucxx17
)
