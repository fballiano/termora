// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermoraImport",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TermoraImport", targets: ["TermoraImport"]),
    ],
    dependencies: [
        .package(path: "../TermoraModel"),
    ],
    targets: [
        .target(name: "TermoraImport", dependencies: ["TermoraModel"]),
        .testTarget(name: "TermoraImportTests", dependencies: ["TermoraImport", "TermoraModel"]),
    ]
)
