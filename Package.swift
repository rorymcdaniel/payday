// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Payday",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Payday", targets: ["Payday"])],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
        .target(name: "PaydayCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "Payday", dependencies: ["PaydayCore"]),
        .testTarget(name: "PaydayCoreTests", dependencies: ["PaydayCore"]),
        .testTarget(name: "PaydayTests", dependencies: ["Payday", "PaydayCore"])
    ],
    swiftLanguageModes: [.v5]
)
