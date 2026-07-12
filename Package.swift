// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ajman",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Ajman", targets: ["Ajman"])],
    targets: [.executableTarget(name: "Ajman")]
)
