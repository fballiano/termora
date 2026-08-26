// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermoraModel",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TermoraModel", targets: ["TermoraModel"]),
    ],
    targets: [
        .target(name: "TermoraModel"),
        .testTarget(name: "TermoraModelTests", dependencies: ["TermoraModel"]),
    ]
)
