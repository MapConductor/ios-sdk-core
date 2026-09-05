// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import Foundation
import PackageDescription

let frameworkLibraryType: Product.Library.LibraryType? =
    ProcessInfo.processInfo.environment["MAPCONDUCTOR_BUILD_XCFRAMEWORK"] == "1" ? .dynamic : nil

let package = Package(
    name: "mapconductor-core",
    platforms: [
        // "15.0" specifically has a known Swift ABI bug; CocoaPods silently elevates any
        // source-compiled pod declaring "15.0" to "15.1", but a *prebuilt* xcframework archived
        // from this Package.swift bakes in whatever is declared here literally - so this must say
        // "15.1" outright to avoid a deployment-target mismatch between this pod (compiled fresh
        // in the consuming app) and any downstream provider vendored as a prebuilt xcframework.
        .iOS("15.1"),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "MapConductorCore",
            type: frameworkLibraryType,
            targets: ["MapConductorCore"]
        ),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        // The Rust PNG encoder. Built and packaged by the
        // mapconductor-vectortile repo (scripts/build-ios-core-png.sh) and
        // copied here by its scripts/sync-sdk.sh.
        // The Rust PNG encoder. The archive and its header travel separately:
        // Xcode merges every linked XCFramework's Headers into one include
        // directory, so two of them shipping a module.modulemap collide, which
        // anything depending on both this and MvtRender would hit.
        .binaryTarget(name: "TilePng", path: "TilePng.xcframework"),
        .target(name: "CTilePng"),
        .target(
            name: "MapConductorCore",
            dependencies: ["CTilePng", "TilePng"]
        ),
        .testTarget(
            name: "MapConductorCoreTests",
            dependencies: ["MapConductorCore"],
            // ズーム換算のゴールデン表。移行前の ios-for-* の実装が返した値そのもの。
            resources: [.process("Resources")]
        ),
    ]
)
