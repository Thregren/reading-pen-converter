// swift-tools-version: 6.0
import PackageDescription

var products: [Product] = [.executable(name: "penconvert", targets: ["PenCLI"])]
var targets: [Target] = [
    .target(
        name: "CMP3Decoder",
        exclude: ["LICENSE", "UPSTREAM.md"],
        publicHeadersPath: "include",
        linkerSettings: [.linkedLibrary("bcrypt", .when(platforms: [.windows]))]
    ),
    .target(name: "PenCore", dependencies: ["CMP3Decoder"]),
    .executableTarget(name: "PenCLI", dependencies: ["PenCore"])
]

#if os(macOS)
products.append(.executable(name: "PenMac", targets: ["PenMac"]))
targets.append(.executableTarget(name: "PenMac", dependencies: ["PenCore"]))
targets.append(.testTarget(name: "PenCoreTests", dependencies: ["PenCore"]))
#endif

let package = Package(
    name: "ReadingPenConverter",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
