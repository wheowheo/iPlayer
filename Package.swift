// swift-tools-version: 6.0
import PackageDescription

let ffmpegPath = "/opt/homebrew/opt/ffmpeg"

let package = Package(
    name: "iPlayer",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(
            name: "CFFmpeg",
            pkgConfig: nil,
            providers: [.brew(["ffmpeg"])]
        ),
        .executableTarget(
            name: "iPlayer",
            dependencies: ["CFFmpeg"],
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
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AppKit"),
                .linkedFramework("QuartzCore"),
            ]
        ),
    ]
)
