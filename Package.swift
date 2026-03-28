// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let ffmpegPath = "\(packageDir)/Vendor/ffmpeg"

let package = Package(
    name: "iPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: nil,
            providers: []
        ),
        .executableTarget(
            name: "iPlayer",
            dependencies: ["CFFmpeg"],
            resources: [
                .copy("Resources/YOLOv3Tiny.mlmodelc"),
            ],
            swiftSettings: [
                .unsafeFlags([
                    "-I\(ffmpegPath)/include",
                ]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-L\(ffmpegPath)/lib",
                    "-I\(ffmpegPath)/include",
                ]),
                .linkedLibrary("avcodec"),
                .linkedLibrary("avformat"),
                .linkedLibrary("avutil"),
                .linkedLibrary("swscale"),
                .linkedLibrary("swresample"),
                .linkedLibrary("z"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreServices"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Security"),
                .linkedFramework("CoreML"),
                .linkedFramework("Vision"),
            ]
        ),
    ]
)
