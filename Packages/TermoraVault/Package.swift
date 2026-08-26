// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermoraVault",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TermoraVault", targets: ["TermoraVault"]),
    ],
    dependencies: [
        .package(path: "../TermoraModel"),
    ],
    targets: [
        .target(name: "TermoraVault", dependencies: ["TermoraModel"]),
        .testTarget(name: "TermoraVaultTests", dependencies: ["TermoraVault", "TermoraModel"]),
    ]
)
