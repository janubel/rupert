// swift-tools-version: 6.0
// The Rupert iPhone app: a Hotwire Native shell around a Rupert instance. Built on Linux with
// omarchy-apple-dev (xtool), or with Xcode on a Mac. See README.md.
import PackageDescription

let package = Package(
    name: "Rupert",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "Rupert", targets: ["Rupert"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hotwired/hotwire-native-ios", exact: "1.3.1"),
    ],
    targets: [
        .target(
            name: "Rupert",
            dependencies: [
                .product(name: "HotwireNative", package: "hotwire-native-ios"),
            ],
            resources: [
                .process("Assets.xcassets"),
                .copy("Resources/path-configuration.json"),
                .copy("Resources/PrivacyInfo.xcprivacy"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
