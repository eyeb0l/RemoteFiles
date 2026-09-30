// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteFiles",
    platforms: [.iOS("27.0"), .macOS(.v15)],
    products: [
        .library(name: "RemoteFilesCore", targets: ["RemoteFilesCore"]),
        .library(name: "RemoteFilesUI", targets: ["RemoteFilesUI"])
    ],
    dependencies: [
        .package(path: "Vendor/Citadel"),
        .package(path: "Vendor/Textual"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4"..<"0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.0.0")
    ],
    targets: [
        .target(name: "RemoteFilesCore", dependencies: [
            .product(name: "Citadel", package: "Citadel"),
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .target(name: "RemoteFilesUI", dependencies: ["RemoteFilesCore", .product(name: "Textual", package: "textual")]),
        .testTarget(name: "RemoteFilesCoreTests", dependencies: ["RemoteFilesCore", "RemoteFilesUI"])
    ],
    swiftLanguageModes: [.v5]
)
