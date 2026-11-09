// swift-tools-version: 6.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let packageName = "PowerSync"

// Set this to the absolute path of your powersync-sqlite-core checkout if you want to use a
// local build of the core extension.
let localCoreExtension: String? = nil

// Our target and dependency setup is different when a local Kotlin SDK is used. Without the local
// SDK, we have no package dependency on Kotlin and download the XCFramework from Kotlin releases as
// a binary target.
// With a local SDK, we point to a `Package.swift` within the Kotlin SDK containing a target pointing
// towards a local framework build
var conditionalDependencies: [Package.Dependency] = []
var conditionalTargets: [Target] = []

var corePackageName = "powersync-sqlite-core-swift"
if let corePath = localCoreExtension {
    conditionalDependencies.append(.package(path: corePath))
    corePackageName = "powersync-sqlite-core"
} else {
    // Not using a local build, so download from releases
    conditionalDependencies.append(
        .package(
            url: "https://github.com/powersync-ja/powersync-sqlite-core-swift.git",
            exact: "0.4.13",
        ))
}

// The default value normally specifies that the library is compatible with both static and dynamic linking,
// where the value used is typically specified by the consumer - which is usually defaulted to static linking.
// It's not straight forward to configure the linking option used by XCode consumers - specifying
// this additional product allows consumers to add it to their project, forcing dynamic linking.
// Dynamic linking is particularly important for XCode previews.
// Not on Windows: a dynamic product there makes every client import PowerSync's symbols from a DLL,
// even when it links PowerSync statically.
var dynamicProducts: [Product] {
    #if os(Windows)
    []
    #else
    [.library(name: "\(packageName)Dynamic", type: .dynamic, targets: ["PowerSync"])]
    #endif
}

// The GRDB integration is left out on Linux: PowerSyncGRDB imports the Apple SDKs' SQLite3 module,
// and GRDB would need the system SQLite's headers.
#if os(Linux)
let grdbProducts: [Product] = []
let grdbDependencies: [Package.Dependency] = []
let grdbTargets: [Target] = []
#else
let grdbProducts: [Product] = [.library(name: "PowerSyncGRDB", targets: ["PowerSyncGRDB"])]
let grdbDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.0")
]
let grdbTargets: [Target] = [
    .target(
        name: "PowerSyncGRDB",
        dependencies: [
            .target(name: "PowerSync"),
            .product(name: "GRDB", package: "GRDB.swift")
        ]
    ),
    .testTarget(
        name: "PowerSyncGRDBTests",
        dependencies: ["PowerSync", "PowerSyncGRDB"]
    )
]
#endif

let package = Package(
    name: packageName,
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .watchOS(.v9),
        .tvOS(.v15),
    ],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: packageName,
            targets: ["PowerSync"]
        )
    ] + grdbProducts + dynamicProducts,
    dependencies: conditionalDependencies + grdbDependencies + [
        .package(url: "https://github.com/powersync-ja/CSQLite.git", exact: "3.51.2"),
        .package(url: "https://github.com/apple/swift-async-algorithms.git", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.4.0")
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: packageName,
            dependencies: [
                .target(name: "PowerSyncCoreShim"),
                .product(name: "CSQLite", package: "CSQLite"),
                .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                .product(name: "BasicContainers", package: "swift-collections"),
                .product(name: "DequeModule", package: "swift-collections")
            ]
        ),
        .target(
            name: "PowerSyncCoreShim",
            dependencies: [
                // Apple platforms link the prebuilt xcframework. On Windows and Linux the core
                // extension is the release's `powersync_x64.dll` or `libpowersync_x64.so`, loaded
                // at runtime (see `registerPowerSyncCoreExtension`).
                .product(
                    name: "PowerSyncSQLiteCore", package: corePackageName,
                    condition: .when(platforms: [
                        .macOS, .macCatalyst, .iOS, .tvOS, .watchOS, .visionOS,
                    ])),
            ],
        ),
        .testTarget(
            name: "PowerSyncTests",
            dependencies: ["PowerSync"]
        )
    ] + grdbTargets + conditionalTargets
)
