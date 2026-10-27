// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IPTVMac",
    platforms: [.macOS("13.0"), .iOS("17.0")],
    products: [
        .executable(name: "IPTVMac", targets: ["IPTVMac"]),
        .executable(name: "iptvprobe", targets: ["iptvprobe"]),
        .library(name: "IPTVMacCore", targets: ["IPTVMacCore"]),
    ],
    targets: [
        .target(name: "IPTVMacCore"),
        // Brand assets are copied next to the binary by build_app.sh, not bundled by
        // SwiftPM, so keep them out of the target's sources.
        .executableTarget(name: "IPTVMac", dependencies: ["IPTVMacCore"], exclude: ["Resources"]),
        .executableTarget(name: "iptvprobe", dependencies: ["IPTVMacCore"]),
        .testTarget(name: "IPTVMacCoreTests", dependencies: ["IPTVMacCore"]),
    ],
    swiftLanguageModes: [.v5]
)
