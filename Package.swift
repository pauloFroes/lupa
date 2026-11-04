// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lupa",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Lupa",
            path: "Sources/Lupa"
        ),
    ]
)
