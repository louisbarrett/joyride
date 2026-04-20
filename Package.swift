// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Lovejoy",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Lovejoy", targets: ["Lovejoy"])
    ],
    targets: [
        .executableTarget(
            name: "Lovejoy",
            path: "Sources/Lovejoy",
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
