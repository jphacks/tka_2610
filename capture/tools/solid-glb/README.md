# solid-glb：立体の物の写真から GLB を作る

数枚の写真と設定ファイル（JSON）から、単純な立体の GLB を作る道具です。形はプログラムが組み立て、AI（または人）は写真を見て設定ファイルを書き、できあがりを見比べます。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

- 入力：真上からの写真 1 枚（必須）と、横からの写真（高さを読むためと、見比べるため）
- 出力：`model.glb`、`compare.jpg`（写真とモデルを同じ向きで並べた画像）、`report.json`
- 単位はメートル、+Y が上、底が y = 0、正面が +Z

## 作れる形

| テンプレート | 向いている物 | 仕組み |
|---|---|---|
| `slab` | 上が平らな物（箱、板、トレー、操作盤、本、ふたのある容器） | 真上の写真で輪郭をなぞり、同じ輪郭の層を積む。上面には真上の写真をまっすぐに直して貼る。丸い部品（ボタン、つまみ、ねじ）を上に載せる |

上が平らでない物（丸いかたまり、動物の形など）は、この版では作れません。作れないと判断したら、その場で別の処理を書く前に、そのことを報告してください。

## 準備（初回だけ）

```sh
cd tools/solid-glb
npm ci                 # three・gltf-validator・playwright（描画と検証に使う）
npx playwright install chromium
python3 -c "import cv2, numpy, mapbox_earcut"   # 無ければ pip install numpy opencv-python-headless mapbox_earcut
```

`capture/` で `scripts/install-mcp.sh --tools-only` を実行すると、この準備（Python は `tools/.venv` に入る）を flat-art-glb の分もまとめて行います。MCP サーバーの `photo_grid`・`build_model`・`check_model` はこの環境で動き、手順の 2〜5 を AI が MCP のツールで行えます（[mcp-server/README.md](../../mcp-server/README.md)）。

## 手順

画像を見るのは、**写真を 1 回ずつ、格子を重ねた真上の写真を 1 回、`top_overlay.jpg` を 1 回、`compare.jpg` を 1 回** が目安です。

1. **写真を見て、向きを決める。** どの辺が正面（手前）か、どの写真がどの向きかを決めます。正面は、使う人が向かう側です。
2. **真上の写真に格子を重ねて、位置を読む。**
   ```sh
   python3 tools/solid-glb/solidglb.py grid 真上.png top_grid.jpg
   python3 tools/solid-glb/solidglb.py grid 真上.png part.jpg 0.5 0.2 1.0 0.6    # 一部を拡大（x0 y0 x1 y1）
   ```
   位置はすべて「写真の幅・高さに対する割合」（x は右、y は下）で読みます。コマンドは `capture/` から書いています。
3. **設定ファイルを書く。** 下の例を写して直します。置き場所は写真と同じフォルダが楽です（写真の場所は設定ファイルからの相対パス）。
4. **作る。**
   ```sh
   python3 tools/solid-glb/solidglb.py build 設定.json --out out
   ```
   出てきた数字（大きさ、部品の数、`features_not_snapped`）を読み、`out/top_overlay.jpg` を 1 回見ます。緑の線が輪郭、赤い丸が丸い部品です。ずれていたら設定を直して作り直します。
5. **確かめる。**
   ```sh
   python3 tools/solid-glb/solidglb.py check out
   ```
   検証のエラーが 0 件であることを確かめ、`out/compare.jpg` を 1 回見ます（1 組ごとに、左が写真、右がモデル）。
6. `out/model.glb` と `out/compare.jpg` を渡します。仮定した値（大きさ、層の高さ）を一言添えます。

## 設定ファイル（`slab`）

```json
{
  "template": "slab",
  "top": {
    "photo": "top.png",
    "corners": [[0.12, 0.10], [0.88, 0.11], [0.93, 0.90], [0.07, 0.89]],
    "width_mm": 200
  },
  "outline": [[0.13, 0.11], [0.87, 0.12], [0.92, 0.89], [0.08, 0.88]],
  "outline_round_mm": 5,
  "layers": [
    {"name": "base", "height_mm": 30, "inset_mm": 0, "material": {"color": [0.2, 0.2, 0.22], "roughness": 0.6}},
    {"name": "lid", "height_mm": 4, "inset_mm": 0, "texture": "top", "material": {"color": [0.8, 0.8, 0.8], "roughness": 0.3}}
  ],
  "features": [
    {"name": "knobs", "shape": "button", "diameter_mm": 24, "height_mm": 6, "texture": "top", "at": [[0.30, 0.50], [0.70, 0.50]]},
    {"name": "screws", "shape": "disc", "diameter_mm": 6, "height_mm": 1, "material": {"color": [0.75, 0.75, 0.75], "roughness": 0.35, "metallic": 1.0}, "at": [[0.15, 0.15]]}
  ],
  "side_marks": [{"name": "port", "layer": "base", "side": "back", "along_frac": 0.5, "height_frac": 0.5, "size_mm": [9, 3]}],
  "views": [
    {"name": "top", "az": 0, "el": 89.9, "up": [0, 0, -1], "photo": "top.png", "w": 900, "h": 700},
    {"name": "front", "az": 0, "el": 15, "photo": "front.png"}
  ]
}
```

### `top`
- `corners`：上面を囲む長方形の 4 隅。**奥の左、奥の右、手前の右、手前の左** の順（正面に立って見たときの左右）。写真の中で物が回っていてもかまいません。この順番で向きが決まります。
  - 角が丸い・欠けている物は、まっすぐな辺を延ばして交わる点を書きます。写真の外に出てもかまいません（0 より小さい、1 より大きい値を書ける）。
- `width_mm`：左右の幅（奥の左から奥の右まで）の実寸。分からなければ仮定して、仮定したことを報告します。
- `depth_mm`：奥行きの実寸。省くと、写真の遠近から計算します（`report.json` の `depth_from_photo`）。

### `outline`
上面の輪郭を、写真の上で一周なぞった点です（始点と向きは自由）。へこみや面取りも点で書きます。
- 背景が写り込まないよう、**線は縁の少し内側**に置きます。外側にずれると、上面の端に背景の色が帯のように出ます。
- `outline_round_mm`：角を丸める半径。

### `layers`
下から上の順です。どの層も同じ輪郭で、`inset_mm` だけ内側に縮めます（負の値で外側）。
- `height_mm`：層の高さ。横からの写真で、分かっている寸法（幅、ボタン、端子など）と比べて決めます。
- `"texture": "top"` を付けた層の上面に、まっすぐに直した真上の写真を貼ります。ふつうは一番上の層です。
- `material`：側面と底の色（0〜1 の RGB）、`roughness`、`metallic`。

### `features`
上面に載る丸い部品です。同じ大きさの物を 1 組にまとめ、`at` に中心を並べます。
- `shape`：`button`（縁と押す面のあるボタン）、`dome`（丸い粒）、`disc`（平たい円柱。ねじの頭など）。
- `diameter_mm`、`height_mm`：外側の直径と高さ。直径は、格子で読んだ幅 ×（`width_mm` ÷ 上面の幅）で見積もります。
- `"texture": "top"`：部品にも真上の写真の色を貼ります。透明・半透明の部品や、模様のある部品に向きます。付けなければ `material` の色です。
- 位置は自動で直ります：作るときに、まっすぐに直した写真から円を探し、近い円（`snap_tolerance_mm`、既定 4 mm 以内）の中心へ動かします。見つからなかった組は `features_not_snapped` に出ます。止めたい組には `"snap": false` を書きます。
- 部品ごとの結果は `report.json` の `feature_list` にあります（最後の位置。`x_mm` は左の辺から、`z_mm` は奥の辺からの距離。`moved_mm` は動かした距離）。2.5 mm より大きく動いた部品は、作るときに一覧が出ます。別の円に合ってしまうことがあるので、`top_overlay.jpg` で確かめます。

### `side_marks`
側面の小さな暗い四角（端子の口、スイッチの穴など）です。`layer` の壁の `side`（`front`・`back`・`left`・`right`）に付けます。`along_frac` は辺に沿った位置（0〜1）、`height_frac` は層の中の高さ（0〜1）です。

### `views`
見比べる向きです。`photo` を書くと、その写真の右にモデルを並べます。
- `az`：正面（0）から、右側（90）、奥（180）、左側（270）へ回る角度。`el`：見下ろす角度。`zoom`：大きく写す倍率。
- 真上の写真（`el` 89.9）では、`up` に「写真の上が、物のどちら側か」を書きます。奥なら `[0, 0, -1]`、手前なら `[0, 0, 1]`、右なら `[1, 0, 0]`、左なら `[-1, 0, 0]`。

## できないこと

実物で確かめたのは 1 つだけです（上が平らな操作盤。写真 5 枚）。ほかは合成した画像のテストです。

- 上が平らでない形、斜めの面、丸い側面は作りません。手前と奥で厚みが違う物（くさび形）も、同じ厚みの箱になります。
- 層はどれも同じ輪郭です（縮める・広げるだけ）。
- 部品は丸い物だけです。四角いボタンやレバーは作りません。
- 側面と底には写真を貼りません（色だけ）。底の細かい形は作りません。
- 実寸は写真からは分かりません。`width_mm` は測るか、仮定します。
- 透明な素材は不透明な色で表します。

## テスト

```sh
python3 -m unittest discover -s tools/solid-glb/tests   # numpy・OpenCV・mapbox_earcut が要る（Node.js は要らない）
```

合成した写真（遠近のついた箱と丸い部品）から作り、大きさ・部品の位置合わせ・GLB の中身を確かめます。
