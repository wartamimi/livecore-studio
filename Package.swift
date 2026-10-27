// swift-tools-version:5.9
// LiveCore Studio — Swift Package manifest.
//
// Targets:
//   CAtomics          C11 atomics shim (lock-free primitives for real-time threads). Portable.
//   CObjCSupport      Objective-C @try/@catch shim so a misbehaving capture driver cannot crash the app.
//   LiveCoreCore      Platform-independent logic: switcher state, transitions, layout math,
//                     audio DSP, FLV/AMF0/RTMP protocol (sans-IO). Builds & tests on Linux + macOS.
//   LiveCoreEngine    macOS-only engines: AVFoundation capture, Metal compositor, Core Audio mixer,
//                     VideoToolbox/AAC encoders, RTMP transport (Network.framework), AVAssetWriter.
//   LiveCoreUI        SwiftUI operator interface (macOS) + localisation resources (en, id).
//   LiveCoreStudio    App entry point (App/). On other platforms it prints a notice and exits.
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
    ],
    targets: [
        .target(name: "CAtomics"),
        .target(name: "CObjCSupport"),   // NSException guard for capture-driver calls (Apple only)
        .target(name: "LiveCoreCore", dependencies: ["CAtomics"]),
        .target(name: "LiveCoreEngine", dependencies: [
            "LiveCoreCore", "CAtomics", "CObjCSupport",
        ]),
        .target(
            name: "LiveCoreUI",
            dependencies: ["LiveCoreEngine", "LiveCoreCore"],
            resources: [.process("Resources")]
        ),
        .executableTarget(name: "LiveCoreStudio", dependencies: ["LiveCoreUI"], path: "App"),
        .executableTarget(name: "livecore-rtmp-push", dependencies: ["LiveCoreCore"]),
        .executableTarget(name: "livecore-transition-dump", dependencies: ["LiveCoreCore"]),
        .testTarget(name: "LiveCoreCoreTests", dependencies: ["LiveCoreCore"]),
    ]
)
