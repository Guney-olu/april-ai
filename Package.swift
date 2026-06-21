// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AprilAI",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AprilAI", targets: ["AprilAI"])
    ],
    targets: [
        .executableTarget(
            name: "AprilAI",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("PDFKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Security"),
                .linkedFramework("SceneKit"),
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
