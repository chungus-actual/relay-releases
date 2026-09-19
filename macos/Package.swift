// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RelayMac",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Relay", targets: ["RelayMac"])],
    targets: [
        .binaryTarget(name: "Sparkle", path: ".build/dependencies/Sparkle.xcframework"),
        .executableTarget(name: "RelayMac", dependencies: ["Sparkle"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])])
    ]
)
