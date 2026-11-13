// swift-tools-version: 5.9
import PackageDescription

// Mac で受け取った撮影セッションから、RealityKit の PhotogrammetrySession で 3D モデル（USDZ）を作るツール。
// session.json の読み込みは iPhone アプリと同じ CaptureCore を使う（形を二重に持たない）。
let package = Package(
    name: "MemoriaReconstruct",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "memoria-reconstruct", targets: ["memoria-reconstruct"]),
    ],
    dependencies: [
        .package(path: "../../ios/Packages/CaptureCore"),
    ],
    targets: [
        .target(
            name: "ReconstructKit",
            dependencies: [.product(name: "CaptureCore", package: "CaptureCore")]
        ),
        .executableTarget(name: "memoria-reconstruct", dependencies: ["ReconstructKit"]),
        .testTarget(name: "ReconstructKitTests", dependencies: ["ReconstructKit"]),
    ]
)
