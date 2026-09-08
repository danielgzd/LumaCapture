// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LumaCapture",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "LumaCapture", targets: ["LumaCapture"])],
    targets: [
        .target(name: "LumaCaptureCore"),
        .executableTarget(name: "LumaCapture", dependencies: ["LumaCaptureCore"]),
        .testTarget(name: "LumaCaptureCoreTests", dependencies: ["LumaCaptureCore"])
    ],
    swiftLanguageModes: [.v5]
)
