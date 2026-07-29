// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeskHealthOverlay",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "DeskHealthOverlay", targets: ["DeskHealthOverlay"])
    ],
    targets: [
        .executableTarget(
            name: "DeskHealthOverlay",
            path: "Sources/DeskHealthOverlay"
        )
    ]
)
