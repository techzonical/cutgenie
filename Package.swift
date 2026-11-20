// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "Cutzonical",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "CutzonicalCore", exclude: ["Shaders"]),
        .executableTarget(name: "Cutzonical", dependencies: ["CutzonicalCore"]),
        .executableTarget(name: "cutzonicalctl"),
    ]
)
