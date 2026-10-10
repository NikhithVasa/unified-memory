// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "UnifiedMemory",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "UnifiedMemory", targets: ["UnifiedMemory"])],
    targets: [
        .target(
            name: "NativeTemperature",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit")]
        ),
        .target(
            name: "NativeHardware",
            publicHeadersPath: "include",
            linkerSettings: [.linkedFramework("CoreFoundation"), .linkedFramework("IOKit"), .linkedFramework("CoreGraphics")]
        ),
        .executableTarget(name: "UnifiedMemory", dependencies: ["NativeTemperature", "NativeHardware"]),
        .testTarget(name: "UnifiedMemoryTests", dependencies: ["UnifiedMemory", "NativeTemperature", "NativeHardware"])
    ]
)
