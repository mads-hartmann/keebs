// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "keebs",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "keebs", targets: ["keebs"])
    ],
    targets: [
        .executableTarget(name: "keebs")
    ],
    swiftLanguageVersions: [.v5]
)
