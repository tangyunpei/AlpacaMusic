// swift-tools-version: 6.4
import PackageDescription
let package = Package(
    name: "AlpacaMusic",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "AlpacaMusic", targets: ["AlpacaMusic"])],
    targets: [
        .executableTarget(name: "AlpacaMusic", resources: [.copy("Resources")], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "AlpacaMusicTests", dependencies: ["AlpacaMusic"], swiftSettings: [.unsafeFlags(["-warnings-as-errors"])])
    ],
    swiftLanguageModes: [.v6]
)
