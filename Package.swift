// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cutgenie",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CutgenieCore", exclude: ["Shaders"]),
        .executableTarget(name: "Cutgenie", dependencies: ["CutgenieCore"]),
        .executableTarget(name: "cutgeniectl"),
    ]
)
