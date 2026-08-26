// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TermoraSSH",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "TermoraSSH", targets: ["TermoraSSH"]),
    ],
    dependencies: [
        .package(path: "../TermoraModel"),
        // Test only: proves the SFTP client works on a real SSH channel.
        .package(path: "../TermoraSFTP"),
    ],
    targets: [
        .target(name: "TermoraSSH", dependencies: ["TermoraModel"]),
        .testTarget(
            name: "TermoraSSHTests",
            dependencies: ["TermoraSSH", "TermoraModel", "TermoraSFTP"]
        ),
    ]
)
