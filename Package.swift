// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Jobcelis",
    platforms: [
        .macOS(.v13),
        .iOS(.v16),
        .tvOS(.v16),
        .watchOS(.v9)
    ],
    products: [
        .library(name: "Jobcelis", targets: ["Jobcelis"])
    ],
    dependencies: [
        // CryptoKit's API for Linux; Apple platforms use CryptoKit itself
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0")
    ],
    targets: [
        .target(
            name: "Jobcelis",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
            ]
        ),
        .testTarget(name: "JobcelisTests", dependencies: ["Jobcelis"])
    ]
)
