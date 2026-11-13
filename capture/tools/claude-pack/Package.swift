// swift-tools-version: 5.9
import PackageDescription

// 受け取った撮影セッションから、Claude Code などの AI エージェントが 3D モデルを作るときの入力一式
// （向きをそろえて切り抜いた代表の写真・一覧の画像・実寸・粗い形・説明）を作る Mac のツール。
// session.json の読み込みと幾何は iPhone アプリと同じ CaptureCore を使う（形を二重に持たない）。
// 使うのは Foundation・simd・CoreGraphics・ImageIO・CoreImage だけ。
let package = Package(
    name: "MemoriaClaudePack",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "memoria-pack", targets: ["memoria-pack"]),
    ],
    dependencies: [
        .package(path: "../../ios/Packages/CaptureCore"),
    ],
    targets: [
        .target(
            name: "PackKit",
            dependencies: [.product(name: "CaptureCore", package: "CaptureCore")]
        ),
        .executableTarget(name: "memoria-pack", dependencies: ["PackKit"]),
        .testTarget(name: "PackKitTests", dependencies: ["PackKit"]),
    ]
)
