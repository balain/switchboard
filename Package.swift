// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Switchboard",
    platforms: [.macOS("14.4")],
    products: [.executable(name: "Switchboard", targets: ["Switchboard"])],
    targets: [
        .executableTarget(name: "Switchboard"),
        .testTarget(name: "SwitchboardTests", dependencies: ["Switchboard"])
    ]
)
