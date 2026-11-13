# flat-art-glb（平らな作品の写真 1 枚から GLB を作るツール）

子どもの **平らな作品**（色紙を切って貼った工作、紙に描いた絵）を真上から撮った写真 1 枚から、GLB（glTF 2.0）を作ります。AI エージェントが写真を見て設定ファイル（JSON）を書き、このツールを動かし、できたモデルを 1 枚の比較画像で確かめる、という使い方を考えています。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

- 標準の質は **「重ねた紙」** です。紙片を色で切り分け、紙の厚さを付けて、台紙の上に重ねます。
- 関数の集まりとして作っています（`flatart/`）。作品に合う関数だけを AI エージェントが選んで使えます。コマンド（`flatart_glb.py`）はその上の薄い層です。
- **Mac・PC の中だけで動きます。** 何も外へ送りません（`check` の描画も、ローカルのヘッドレスの Chromium で行います）。

やらないこと：紙のしわ、折れた角、絵の具の凹凸（法線マップ）、Web のビューア、立体の作品。

## モード

| モード | 向く作品 | 中身 |
|---|---|---|
| `layers`（既定） | 色紙の貼り絵 | 台紙の板 ＋ 紙片ごとに切り出して厚みを付けた板。紙片の層（何枚目に重なっているか）は自動で決める |
| `plane` | 色で分けられない作品（クレヨンの絵など） | 写真をまっすぐに直して、1 枚の薄い板に貼る |

## 準備

```sh
cd tools/flat-art-glb
pip install -r requirements.txt     # numpy・opencv-python-headless・mapbox_earcut
npm install                         # check で使う three と gltf-validator（node_modules/ は git に入らない）
```

`check` の描画には Playwright（Node.js から `require('playwright')` で読めること）と Chromium が要ります。無いときは、このフォルダで `npm install playwright` と `npx playwright install chromium` を実行するか、手元の Chrome を `CHROME_PATH=/path/to/chrome` で指定します。描画はソフトウェアの WebGL（SwiftShader）で行うので、GPU は要りません。Playwright が無くても `build` とテストは動きます。

## 使い方

コマンドは `capture/` から書いています。

```sh
python3 tools/flat-art-glb/flatart_glb.py build <設定.json> --out <出力フォルダ>
python3 tools/flat-art-glb/flatart_glb.py check <出力フォルダ>
```

`build` が作るもの：

```
model.glb      モデル。単位はメートル、+Y が上、正面は +Z。台紙は X の中央に置き、下の辺が y = 0、表の面が z = 0
report.json    台紙の大きさ（推測したかどうか）、写真の解像度（px/mm）、紙片ごとの名前・グループ・層・範囲（mm）・面積・
               テクスチャか単色か・三角形の数、警告
overlay.jpg    まっすぐに直した写真に、紙片の輪郭と名前・層（L1, L2 …）を描いたもの。写真の外だった所は紫
```

`check` が作るもの：`validation.json`（gltf-validator の結果）、`front.png`・`oblique.png`（three.js で描いた正面と斜め）、**`compare.jpg`**（左から、台紙のまわりで切り抜いた写真・正面・斜め）。ふだんは `compare.jpg` だけを見て、おかしいときに `overlay.jpg` を見ます。

**写真は個人のデータです。** 写真も出力も、tka_2610 の外か、git に入らないフォルダ（このフォルダの `out/` は `.gitignore` 済み）に置いてください。`report.json` には写真の場所（絶対パス）が入ります。

## 設定（JSON）

例は `examples/collage.example.json`（貼り絵）と `examples/plane.example.json`（絵）です。座標は写真の幅・高さに対する割合（x は右、y は下、0〜1）です。

| キー | 意味 |
|---|---|
| `photo` | 写真のファイル（設定ファイルからの相対パスか絶対パス） |
| `mode` | `layers`（既定）か `plane` |
| `sheet.size_mm` | 台紙の 2 辺（mm）。縦か横かは写真から決める。無いときは縦横比から、四つ切 392 × 542・八つ切 271 × 392・A3・B4・A4・B5 の中で近いものを選び、`report.json` に「推測した」と書く（縦横比しか分からないので、A 判と B 判は区別できない） |
| `sheet.thickness_mm` | 紙の厚さ（既定 0.27）。紙片も同じ厚さ |
| `sheet.corners` | 任意。台紙の 4 隅（左上・右上・右下・左下、写真に対する割合）。自動で見つからないときに使う |
| `colors` | 色の名前 → 見本の点の一覧。点のまわりの中央値を見本にし、その色に分けられた画素の中で k-means をして陰の幅も覆う。どの見本からも遠い画素は「不明」 |
| `backing` | 台紙の色の名前（`colors` の 1 つ）。台紙の検出と、明るさのむらの推定に使う |
| `stack` | `layers` のときの紙片のグループ。下から上の順。グループは色の名前のリストで、**最初の色が主な色**、残りは一緒に付いている色（塗り残しの白い縁など）。主な色が 35% 以上ある塊だけを、そのグループの紙片にする（足りない塊は、後のグループに残す） |
| `white_reference` | 任意。白い紙の色の名前。白が無彩色になるようにホワイトバランスを合わせる |
| `min_piece_mm2` | これより小さい紙片は捨てる（既定 150） |

細かい調整（ふだんは要らない）：`primary_share`（0.35）、`color_max_dist`（色の距離の上限、22）、`piece_texture`（`auto`・`photo`・`flat`）、`flat_tolerance`（単色とみなす色のばらつき、12）、`hidden_grow_mm`（8）、`hidden_keep_in_mm`（2.5）、`texture_factor`（写真の解像度の何倍でテクスチャを作るか、2）、`analysis_px_per_mm`（解析の解像度、既定は写真の 2 倍で 2〜4）。

## 中の流れと関数

| 段階 | 関数（`flatart/`） | 貼り絵 | 平らな絵 | 立体の作品 |
|---|---|---|---|---|
| 色の見本と分類 | `segment.ColorClassifier.fit` / `classify` | ○ | ○（台紙の色だけ） | × |
| 台紙の検出 | `rectify.sheet_mask`・`fit_sheet_quad`（辺ごとの頑健な直線のあてはめ。写真の端と角の付近は使わない） | ○ | ○ | × |
| 台紙の大きさ・向き | `rectify.guess_sheet_size`・`oriented_size`・`sheet_orientation` | ○ | ○ | × |
| まっすぐに直す | `rectify.Rectifier`（`warp`・`sheet_to_photo`・`photo_to_sheet`・`native_px_per_mm`） | ○ | ○ | × |
| 紙片の切り出し | `segment.extract_pieces` | ○ | × | × |
| 層の番号 | `layers.assign_layers`（触れている、前のグループの紙片の層 ＋ 1） | ○ | × | × |
| 隠れた部分を補う | `layers.complete_hidden`（上の紙片の下へ、下の紙片を伸ばす。上の紙片からははみ出さない） | ○ | × | × |
| 明るさのむらと色 | `texture.Appearance`（台紙の画素からなめらかな倍率の地図を作る、`set_white`） | ○ | ○ | △（写真の補正だけ） |
| 穴埋め | `texture.normconv_fill` | ○ | ○（写真の外・折れた角） | △ |
| 紙片のテクスチャ | `texture.piece_texture`・`is_uniform`（ほぼ一色なら単色にする） | ○ | × | × |
| 輪郭と板 | `mesh.mask_polygon`・`extrude`・`rectangle` | ○ | ○（板だけ） | × |
| GLB に書く | `glbwriter.GLB` | ○ | ○ | ○ |
| 確かめ | `check.validate`・`render`・`compose` | ○ | ○ | ○ |

○ 使える、△ 一部だけ使える、× 向かない。

## 確認

```sh
python3 -m unittest discover -s tools/flat-art-glb/tests
```

テストは合成の画像（色の図形を台紙に描き、遠近を付けて暗い床に置き、陰を付けたもの）だけを使います。本物の写真もネットワークも使いません。Node.js も要りません。

## 分かっている限界

- 色で紙片を分けるので、**同じ色の紙が重なったり接したりしていると、1 枚になります**（グループの中では層を付けません）。
- 層は「触れているか」で決めます。重ならずに接しているだけの紙片も、上に重なっているとみなします。
- 隠れた部分は、見えている形の凸包を少し広げて補うだけです。大きく隠れた紙片の形は推測になります。
- 台紙の縁からはみ出した紙片は、台紙の範囲で切れます。
- 台紙の検出は、台紙の色が一色で、床と色がはっきり違う前提です。見つからないときは `sheet.corners` を書きます。
- 台紙が大きく反っていると、直線の辺のあてはめと平面の射影変換では、数 mm ずれます。
- `check` の描画は決まった明るさの照明なので、位置・形・模様の確かめ用です。写真より少し明るく出ることがあり、色を厳密に比べるものではありません。
- 紙片の縁の 0.8 mm は、紙片の中の色で埋め直します（台紙の色がにじむのを防ぐため）。紙片の色に分類された画素は残しますが、細い線の文字が縁にかかっているときは消えることがあります。
