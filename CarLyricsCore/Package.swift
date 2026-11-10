// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CarLyricsCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CarLyricsCore", targets: ["CarLyricsCore"]),
    ],
    targets: [
        .target(name: "CarLyricsCore"),
        .testTarget(name: "CarLyricsCoreTests", dependencies: ["CarLyricsCore"]),
    ]
)
