// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Everseq",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "EverseqCore", targets: ["EverseqCore"]),
        .executable(name: "Everseq", targets: ["Everseq"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "EverseqCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Everseq",
            dependencies: ["EverseqCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "EverseqCoreTests",
            dependencies: ["EverseqCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
