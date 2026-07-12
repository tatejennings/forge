// swift-tools-version: 5.10

// Regression harness for the stripped-binary override bug fixed in 0.5.2.
//
// This cannot live in the regular test target: XCTest/Swift Testing bundles are
// never symbol-stripped, so they cannot reproduce the archive-time environment
// (STRIP_INSTALLED_PRODUCT) in which KeyPath descriptions degrade to
// "<computed 0x… (Type)>". scripts/stripped-override-test.sh builds this
// executable in release, strips it, and runs it.

import PackageDescription

let package = Package(
    name: "StrippedOverrideRepro",
    platforms: [
        .macOS(.v13),
    ],
    dependencies: [
        // name: pins the package identity so the harness also works when the
        // repository is checked out under a different directory name.
        .package(name: "Forge", path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "StrippedOverrideRepro",
            dependencies: [
                .product(name: "Forge", package: "Forge"),
            ]
        ),
    ]
)
