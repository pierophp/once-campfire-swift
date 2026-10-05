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
            cSettings: [.define("SQLITE_ENABLE_FTS5"), .define("SQLITE_THREADSAFE", to: "2")]
        ),
        .target(
            name: "CampfireCore",
            dependencies: [
                "CSQLite",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftSoup", package: "SwiftSoup"),
            ]
        ),
        .executableTarget(
            name: "Campfire",
            dependencies: ["CampfireCore", .product(name: "Hummingbird", package: "hummingbird")]
        ),
        .testTarget(
            name: "CampfireTests",
            dependencies: [
                "CampfireCore",
                .product(name: "HummingbirdTesting", package: "hummingbird"),
            ],
            resources: [.copy("Fixtures")]
        ),
    ]
)
