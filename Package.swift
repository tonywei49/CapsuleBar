// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CapsuleBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CapsuleBar",
            path: "Sources/CapsuleBar"
        )
    ]
)
