# capture（iPhone で作品を撮る Memoria Capture）

このアプリの **撮影側** です。iPhone の AR で作品のまわりを決まった方向から撮り、同じ Wi-Fi の Mac へ送ります。受け取った写真は、アプリの作品の詳細の「写真から 3D を作る（試験中）」で選べ、`generator/` の `kt auto` が 3D（GLB）にします（[docs/generator.md](../docs/generator.md)）。

もとは別のリポジトリ（`memoria-capture`）で作り、ここへ取り込みました。手元の PC で試すためのもので、本番（Render）の入れ物にも CI にも入りません。

## 3 つの部分

| フォルダ | 中身 | 動かす場所 |
|---|---|---|
| `ios/` | iPhone のアプリ（SwiftUI・ARKit）。作品の底と大きさを AR のガイドで合わせ、撮る方向を案内して自動で撮り、Vision で作品の切り抜き（マスク）を作って確かめる。共通の型は `ios/Packages/CaptureCore`（Swift Package。Mac でもテストできる） | iPhone（LiDAR は要らない） |
| `receiver/` | 受信サーバー `memoria_receiver.py`（Python 3.9 以上の標準ライブラリだけ）。Bonjour で見つけてもらい、ペアリングコードで iPhone から受け取って、`capture/captures/sessions/<sessionId>/` に置く | Mac |
| `tools/reconstruct/` | `memoria-reconstruct`（Swift の CLI）。受け取った写真から、Apple の RealityKit `PhotogrammetrySession` で 3D（**USDZ**）を作る。**アプリにはまだつないでいません**（アプリが使う GLB ではないため） | Apple シリコンの Mac |

形の決まりは [docs/data-format.md](docs/data-format.md)（`session.json`・写真・マスク）と [docs/transfer-protocol.md](docs/transfer-protocol.md)（iPhone → Mac の転送）にあります。

## アプリへのつながり

```
iPhone（ios/）── Wi-Fi ──▶ 受信サーバー（receiver/）──▶ capture/captures/sessions/<sessionId>/
                                                              │
       アプリのサーバー（backend/src/capture.rs）が一覧にする ◀──┘
       作品の詳細で撮影を選ぶ → 写真を 8 枚まで選んでまっすぐに回す → generator/ の kt auto → GLB → 作品の 3D を差し替える
```

- アプリのサーバーが読むのは `sessions/` の中（転送が終わったもの）だけです。`incoming/`（転送の途中）・`replaced/`（送り直す前の版）は読みません。
- フォルダは `CAPTURE_DATA_DIR`（既定は `capture/captures`）で変えられます。受信サーバーの `--data-dir` と同じフォルダにしてください。
- 使えるのは、写真から 3D を作る機能と同じく `KT_GENERATOR_ENABLED=1` のときだけです。

## 使い方（手元の Mac）

1. 受信サーバーを起動する（[receiver/README.md](receiver/README.md)）。

   ```sh
   cd capture
   python3 receiver/memoria_receiver.py serve --port 8766
   ```

   既定のポート 8765 は、`generator/` が使う Katachi Loop Studio の画面（`http://127.0.0.1:8765`）と同じです。両方を動かすときは `--port` で別の番号にします。
2. iPhone のアプリを Xcode で入れる（`ios/MemoriaCapture.xcodeproj`。署名のチーム `DEVELOPMENT_TEAM` は自分のものに変える）。作品を撮って、送信の画面から Mac へ送る（ペアリングコードは受信サーバーが表示する）。
3. アプリ（tka_2610）のサーバーを `KT_GENERATOR_ENABLED=1` で起動し、作品の詳細の「写真から 3D を作る」で「iPhone で撮った写真から」を選ぶ。

## 確かめ方

```sh
# 受信サーバーのテスト（tka_2610 の一番上から）
python3 -m unittest discover -s capture/receiver/tests -v
# 共通の型（Mac で）
cd capture/ios/Packages/CaptureCore && swift test
# 3D を作るツール
cd capture/tools/reconstruct && swift build && swift test
# iPhone のアプリ（シミュレーター向けに、署名なしでビルドだけ）
xcodebuild -project capture/ios/MemoriaCapture.xcodeproj -scheme MemoriaCapture -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## 気をつけること

- **撮った写真（`capture/captures/`）はリポジトリに入れません**（`capture/.gitignore`）。作品や家の中が写っています。
- `DerivedData/`・`.build/`・`xcuserdata/` も入れません。
