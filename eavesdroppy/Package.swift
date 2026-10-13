// swift-tools-version: 6.2
import PackageDescription
import Foundation

// Personal build (EAVESDROPPY_PERSONAL=1 when the manifest is evaluated): FluidAudio is compiled in as three local
// targets from Vendor/FluidAudio (run tools/vendor_fluidaudio.sh), for in-process transcription and diarization.
// Local targets, not a package dependency: DroppyKit's build script links only the package's own targets into the
// .droplet, so a dependency's code would be missing at load. A Store build omits all of it until the maintainers
// answer (research/swift-port-plan.md, D21).
let personal = ProcessInfo.processInfo.environment["EAVESDROPPY_PERSONAL"] == "1"
let fluidAudioTargets: [Target] = personal ? [
    .target(
        name: "FluidAudio",
        dependencies: ["FastClusterWrapper", "MachTaskSelfWrapper"],
        path: "Vendor/FluidAudio/Sources/FluidAudio",
        resources: [.process("TTS/LuxTts/G2p/Resources")],  // upstream's manifest; only the unused TTS code reads it
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(name: "FastClusterWrapper", path: "Vendor/FluidAudio/Sources/FastClusterWrapper", publicHeadersPath: "include"),
    .target(name: "MachTaskSelfWrapper", path: "Vendor/FluidAudio/Sources/MachTaskSelfWrapper", publicHeadersPath: "include"),
] : []

let package = Package(
    name: "Eavesdroppy",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Eavesdroppy", type: .dynamic, targets: ["Eavesdroppy"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.6.0")
    ],
    targets: fluidAudioTargets + [
        .target(
            name: "Eavesdroppy",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")] + (personal ? ["FluidAudio"] : []),
            // Swift 5 mode: CoreAudio realtime callbacks capture non-Sendable AVAudioFile/AVAudioPCMBuffer.
            swiftSettings: [.swiftLanguageMode(.v5)] + (personal ? [.define("EAVESDROPPY_PERSONAL")] : [])
        ),
        .testTarget(
            name: "EavesdroppyTests",
            dependencies: ["Eavesdroppy"],
            resources: [.copy("Fixtures")],
            swiftSettings: [.swiftLanguageMode(.v5)] + (personal ? [.define("EAVESDROPPY_PERSONAL")] : [])
        ),
        .executableTarget(
            name: "EavesdroppyHarness",
            dependencies: [
                "Eavesdroppy",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        )
    ]
)
