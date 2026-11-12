// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Lupa",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "Lupa",
            path: "Sources/Lupa"
        ),
        .testTarget(
            name: "LupaTests",
            dependencies: ["Lupa"],
            path: "Tests/LupaTests"
        ),
    ],
    // AppKit, AVFoundation and ScreenCaptureKit callbacks are not yet annotated for Swift 6 strict
    // concurrency. The app stays in the Swift 5 language mode until that migration is done.
    swiftLanguageModes: [.v5]
)
