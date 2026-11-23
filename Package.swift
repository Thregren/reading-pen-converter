// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ReadingPenConverter",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "PenMac", targets: ["PenMac"]), .executable(name: "penconvert", targets: ["PenCLI"])],
    targets: [.target(name: "CMP3Decoder", exclude: ["LICENSE", "UPSTREAM.md"], publicHeadersPath: "include"), .target(name: "PenCore", dependencies: ["CMP3Decoder"]), .executableTarget(name: "PenCLI", dependencies: ["PenCore"]), .executableTarget(name: "PenMac", dependencies: ["PenCore"]), .testTarget(name: "PenCoreTests", dependencies: ["PenCore"])]
)
