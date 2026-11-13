# memoria-reconstruct（写真から 3D モデルを作る Mac のツール）

受信サーバーが受け取った撮影セッション（`captures/sessions/<sessionId>/`）の写真から、Apple の RealityKit `PhotogrammetrySession`（Object Capture）で 3D モデル（USDZ）を作ります。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

- **Mac の中だけで動きます。** 写真をクラウドに送りません（RealityKit の処理はすべてローカル）。
- session.json は iPhone アプリと同じ `ios/Packages/CaptureCore` の型で読みます（形を二重に持たない）。
- 元のセッション（`sessions/`）には書き込みません。`incoming/`（転送の途中）は読みません。

必要なもの：Apple シリコンの Mac、macOS 14 以降（`PhotogrammetrySession.isSupported` が true）、Xcode（Swift 5.9 以降）。

## 使い方

```sh
cd tools/reconstruct
swift run -c release memoria-reconstruct <セッションのフォルダ | sessionId | sessionId の先頭> [オプション]

# 例：先頭 4 文字で指定して、速いプレビューを作る
swift run -c release memoria-reconstruct 844B --detail preview
# 例：同じ置き方で撮った写真だけ（基準 ref-2 と基準なし）、マスクを使わずに
swift run -c release memoria-reconstruct 844B --frames ref-2,none --masks off --sensitivity high
```

| オプション | 値（既定） | 意味 |
|---|---|---|
| `--data-dir` | フォルダ（今のフォルダから上へ探した `captures/`、無ければ `capture/captures/`） | 受信フォルダ |
| `--detail` | `preview` `reduced` `medium` `full` `raw`（`medium`） | モデルの細かさ。`preview` は数秒、`medium` で十数秒〜（写真の枚数しだい） |
| `--masks` | `auto` `on` `off`（`auto`） | `auto`：`mask.status` が `confirmed`、または `candidate` で `check.status` が `ok`（`check` が無い前の版も使う）のマスクだけ渡す。`on`：ファイルのあるマスクを全部。`off`：渡さない。マスクを渡さない写真も、写真そのものは使う |
| `--include` | `all` `good`（`all`） | `good`：方向が確定（`direction.confirmed`）・使えるマスク（`auto` の決まり）・置き換え済みでない写真だけ |
| `--frames` | `ref-1,ref-2,none` など（全部） | この基準（`referenceFrameId`）の写真だけ使う。`none` は基準なしの写真 |
| `--ordering` | `unordered` `sequential`（`unordered`） | `PhotogrammetrySession.Configuration.sampleOrdering` |
| `--sensitivity` | `normal` `high`（`normal`） | `featureSensitivity`。模様の少ない物は `high` |
| `--gravity` | `off` `on` `camera`（`off`） | 重力の向きを渡す（試験的。下の「重力」） |
| `--session-masking` | `on` `off`（`on`） | `isObjectMaskingEnabled`。`off` だと渡したマスクも使われない |
| `--poses` | `on` `off`（`on`） | 推定したカメラ位置も求め、ARKit の位置と比べて report.json に書く |
| `--out` | フォルダ | 出力先（`sessions/`・`incoming/` の中は不可） |

除いた写真・マスクを渡さなかった写真は、理由と一緒に画面と report.json に必ず出します。進み具合はターミナルでは 1 行で書き換えて表示します。Ctrl-C で処理を止めます（終了コード 130。もう一度押すとすぐ終了）。失敗すると終了コード 1 です。

## 出力

```
captures/reconstructions/<sessionId>/<UTC 時刻>-<detail>/
  model.usdz     3D モデル（できたときだけ）。Finder のクイックルック、または qlmanage -p model.usdz で見られる
  report.json    写真ごとの使い方（除いた理由・マスクの有無と理由・マスクの面積・PhotogrammetrySession での扱い（used / skipped / invalid））、
                 オプション、設定、時間（段階ごと）、PhotogrammetrySession のメッセージとエラー、サンプル数、
                 モデルの大きさ（バイト・頂点・三角形・範囲）、_receipt.json の manifestHash、推定したカメラ位置と ARKit との比較
  README.md      結果の短い説明
```

`captures/` は git に入りません。

## 写真の渡し方（調べた結果）

macOS 26 の SDK（`RealityFoundation.swiftinterface` と `.swiftdoc` のドキュメントコメント）で確かめました。

- **写真**：保存したままの JPEG（センサーの向き、4032 × 3024）を回さずに `kCVPixelFormatType_32BGRA` の CVPixelBuffer にします（`image` のドキュメントが受け付ける形式の 1 つ）。マスクと K も同じ向きです。
- **マスク**：PNG（8bit グレー、255 = 作品）をそのまま `kCVPixelFormatType_OneComponent8`・写真と同じ大きさで `objectMask` に渡します。ドキュメント：「OneComponent8 で image と同じ幅・高さ。マスクが 0（黒）の画素は無視する（`isObjectMaskingEnabled` が false のときを除く）」。
- **カメラの姿勢と内部パラメータ（K）は渡せません。** `PhotogrammetrySample` で書き込めるのは `metadata`・`depthDataMap`・`gravity`・`objectMask` だけです。`camera`（`intrinsics`・`transform`）・`boundingBox` は読み取り専用で、`ObjectCaptureSession` で撮った HEIC を `init(contentsOf:)` で読んだときだけ入ります。姿勢は PhotogrammetrySession が写真から自分で推定します（ARKit の姿勢は report.json の比較にだけ使う）。
- **metadata**：JPEG 自身の ImageIO のプロパティに、K から計算した `{Exif}.FocalLenIn35mmFilm`（f_px × 43.27 mm ÷ 画像の対角の画素数。センサーの大きさは要らない）を足します。`init(contentsOf:)` が作る metadata も同じ入れ子の辞書の形でした。メーカー・機種名は session.json に EXIF の形で無いので入れません。
- **重力**：ドキュメントは「iPhone などが撮影時に記録する重力ベクトル。画像の向きを表し、特徴点の対応付けに使う」とだけあり、**座標系と符号が書かれていません**。そのため既定は `off` です。`on` は CMDeviceMotion の形（縦持ちの端末座標：+X 右端、+Y 上端、+Z 画面の手前、単位 g、地面の向き）、`camera` は保存した画像の軸（ARKit のカメラ座標）です。どちらも `cameraToWorld` の回転から求めます（世界の重力 (0, −1, 0) をカメラ座標に変換）。合成した写真では、off・on・camera のどれでもモデルは同じく上向きにでき、違いは見えませんでした。

## 写真の枚数の目安

Apple の案内では、隣り合う写真が大きく重なるように、数十枚〜100 枚以上を撮ります。このツールで試した結果も同じでした。

- 模様のはっきりした合成の物体でも、1 周 8 枚（45° おき）では 8 枚中 5 枚しか位置が決まりませんでした。12 枚（30° おき）で 12 枚中 11 枚、2 段（仰角 25°・50°）× 12 枚で 24 枚中 23 枚です。
- 実際のセッション（白いマウス、1 周 8 方向 × 2 回、計 19 枚）では、全部をまとめると位置合わせ（imageAlignment）で失敗しました。1 回目と 2 回目のあいだでマウスの下のマットを外していて、2 つの違う場面が混ざっていたためです。片方ずつ、マスクなしで使うと、ref-1 で 8 枚中 3 枚、ref-2 と基準なしで 11 枚中 6 枚の位置が決まりました。できたモデルは机の天板の一部で、マウスは天板の模様と浅いふくらみになっただけです。
- 作品だけのマスクを渡すと、どの組み合わせでも位置合わせで失敗しました。白く模様の少ない物では、マスクで背景を消すと対応点が足りなくなります。

撮り方の目安：作品とまわりを最後まで動かさない。1 周 24 枚（15° おき）× 仰角 3 段（低・中・高）＋真上から数枚で、70〜100 枚ほど。模様の少ない作品は、新聞や柄のある布など模様のある面に置きます。作品が画面の 2〜5% しか写っていないときは、もっと近づきます。

## 確認

```sh
swift test   # マスクの選び方・--include good・重力の座標変換・35mm 換算・オプション・位置の比べ方
```
