// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LectoAICore",
    platforms: [.macOS("26.0")],
    products: [.library(name: "LectoAICore", targets: ["LectoAICore"])],
    targets: [
        .target(name: "LectoAICore"),
        .testTarget(name: "LectoAICoreTests", dependencies: ["LectoAICore"])
    ],
    swiftLanguageModes: [.v6]
)
