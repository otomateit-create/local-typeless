// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "TypelessLocal",
    platforms: [
        // SpeechAnalyzer / SpeechTranscriber (moteur de dictée on-device) exigent macOS 26.
        .macOS("26.0")
    ],
    targets: [
        .executableTarget(
            name: "TypelessLocal",
            path: "Sources/TypelessLocal"
        )
    ]
)
