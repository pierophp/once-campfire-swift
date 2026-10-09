// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Campfire",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "campfire-swift", targets: ["Campfire"]),
        .library(name: "CampfireCore", targets: ["CampfireCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.7.0"),
    ],
    targets: [
        .target(
            name: "CSQLite",
            path: "Vendor/SQLite",
            publicHeadersPath: ".",
            cSettings: [
                .define("SQLITE_ENABLE_FTS5"), .define("SQLITE_THREADSAFE", to: "2"),
                // Memory statistics take a global mutex on every allocation; nothing reads them.
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                // Release C targets otherwise build with -Os; SQLite is on every request's path.
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ]
        ),
        .systemLibrary(name: "CZlib", pkgConfig: "zlib"),
        .target(
            name: "CampfireCore",
            dependencies: [
                "CSQLite",
                "CZlib",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ],
            resources: [.copy("Resources")]
        ),
        .executableTarget(
            name: "Campfire",
            dependencies: ["CampfireCore", .product(name: "Hummingbird", package: "hummingbird")]
        ),
        .testTarget(
            name: "CampfireTests",
            dependencies: [
                "CampfireCore",
                "CSQLite",
                "CZlib",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
