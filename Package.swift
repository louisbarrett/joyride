// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Joyride",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Joyride", targets: ["Joyride"])
    ],
    targets: [
        .executableTarget(
            name: "Joyride",
            path: "Sources/Joyride",
            exclude: ["Resources/Info.plist"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Combine"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Carbon")
            ]
        )
    ]
)
