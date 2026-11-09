// swift-tools-version: 5.9
import PackageDescription

// 撮影アプリの「純粋なロジック」部分。iOS アプリと macOS の `swift test` の両方でビルドする。
// 使ってよいのは Foundation・simd・CryptoKit だけ（capture-e2e は macOS 用の確認ツールで ImageIO も使う）。
let package = Package(
    name: "CaptureCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .executable(name: "capture-e2e", targets: ["capture-e2e"]),
    ],
    targets: [
        .target(name: "CaptureCore"),
        .executableTarget(name: "capture-e2e", dependencies: ["CaptureCore"]),
        .testTarget(name: "CaptureCoreTests", dependencies: ["CaptureCore"]),
    ]
)
