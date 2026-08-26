// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermoraSFTP",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TermoraSFTP", targets: ["TermoraSFTP"]),
    ],
    targets: [
        .target(name: "TermoraSFTP"),
        .testTarget(name: "TermoraSFTPTests", dependencies: ["TermoraSFTP"]),
    ]
)
