// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Somnia",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Somnia",
            path: "Sources/Somnia"
        )
    ]
)
