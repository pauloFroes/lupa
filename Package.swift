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
    ],
    // O AppKit e o ScreenCaptureKit ainda não estão prontos para o modo estrito do Swift 6.
    swiftLanguageModes: [.v5]
)
