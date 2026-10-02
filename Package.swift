// swift-tools-version: 5.9
import PackageDescription

// OpenSSL's libcrypto, built statically for iOS and distributed as a Swift
// package. See README.md.
//
// The binary is never committed. On main the binary target is the local
// build/OpenSSLCrypto.xcframework (run scripts/build-xcframework.sh). Each
// release tag points at a commit where scripts/stamp-release.sh filled in the two
// values below, which switches the target to that release's GitHub asset.
// Depend on a tag, never on a branch.
let releaseVersion = ""
let releaseChecksum = ""

let openSSLCrypto: Target = releaseChecksum.isEmpty
    ? .binaryTarget(
        name: "OpenSSLCrypto",
        path: "build/OpenSSLCrypto.xcframework"
    )
    : .binaryTarget(
        name: "OpenSSLCrypto",
        url: "https://github.com/Backbone-Labs/openssl-ios/releases/download/v\(releaseVersion)/OpenSSLCrypto.xcframework.zip",
        checksum: releaseChecksum
    )

// Named after its one product so Xcode's generated scheme is "OpenSSLCrypto"
// whether it names schemes by package or by product (both have shipped).
// Consumers refer to the package by its URL identity, "openssl-ios".
let package = Package(
    name: "OpenSSLCrypto",
    platforms: [.iOS(.v17), .tvOS(.v17)],
    products: [
        .library(name: "OpenSSLCrypto", targets: ["OpenSSLCrypto", "OpenSSLCryptoPrivacy"]),
    ],
    targets: [
        openSSLCrypto,

        // Carries PrivacyInfo.xcprivacy into the app. A static-library binary
        // target cannot hold resources, so the manifest needs a source target.
        .target(
            name: "OpenSSLCryptoPrivacy",
            path: "Sources/OpenSSLCryptoPrivacy",
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
    ]
)
