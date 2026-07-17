// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Ajman",
    platforms: [.macOS(.v12)],
    products: [
        .executable(name: "Ajman", targets: ["Ajman"]),
        .executable(name: "ajman-tools", targets: ["AjmanTools"]),
        .executable(name: "ajman-hook", targets: ["AjmanHook"]),
    ],
    targets: [
        .executableTarget(name: "Ajman"),
        .executableTarget(name: "AjmanTools"),
        .executableTarget(name: "AjmanHook"),
    ]
)
