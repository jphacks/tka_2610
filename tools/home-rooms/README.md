# tools/home-rooms — 4 部屋の家の建物（開発用シェル）

> [!NOTE]
> ここで作る GLB は **開発用** です。アプリの 4 部屋対応を先に作って試すためのもので、
> 本番品質の GLB は別に納品してもらい、同じファイル名で置き換えます。本番の GLB の仕様は [docs/house-assets.md](../../docs/house-assets.md) にあります。

## できるもの

`backend/static/models/rooms/` に 4 つの GLB を書き出します。部屋ごとに部屋の中心を原点にしていて、アプリが各部屋の origin へ平行移動して置きます（回転なし）。

| ファイル | 部屋 | origin (x, z) | 内寸 | 壁 | 大きさ |
|---|---|---|---|---|---|
| `hub.glb` | 中央 | (0, 0) | 8 × 8 m | 4 面。西・東・北の中央に開口（有効幅 2.10 m・高さ 2.60 m） | 約 2.96 MB |
| `left.glb` | 左 | (−7.24, 0) | 6 × 6 m | 3 面（東を開ける） | 約 2.25 MB |
| `right.glb` | 右 | (7.24, 0) | 6 × 6 m | 3 面（西を開ける） | 約 2.25 MB |
| `front.glb` | 前（−Z 側、入口から見て正面） | (0, −7.24) | 6 × 6 m | 3 面（南を開ける） | 約 2.25 MB |

隣の部屋とは hub の壁を共有します（通路なし）。開口の下の帯（壁の厚さ 0.24 m）の床は `hub.glb` に入っています。
ノード名・extras・材質の決まりは docs/house-assets.md の「ノードと extras」を見てください。

## 作り直す

Python 3.10 以上が要ります（このリポジトリでは Homebrew の python3.12 で確認）。`.venv` は git に入りません。

```sh
python3.12 -m venv tools/home-rooms/.venv
tools/home-rooms/.venv/bin/pip install -r tools/home-rooms/requirements.txt
tools/home-rooms/.venv/bin/python tools/home-rooms/build_rooms.py
python3 tools/home-rooms/check_rooms.py
```

- `build_rooms.py` は 2 秒ほどで 4 つの GLB を上書きします。同じ入力なら毎回同じバイト列になります。
- `check_rooms.py` は Python の標準ライブラリだけで動きます（venv は要りません）。最後に `ALL CHECKS PASSED` と出れば OK です。
  別のフォルダの GLB（納品された本番の GLB など）も `python3 tools/home-rooms/check_rooms.py <フォルダ>` で同じように調べられます。

## 中身

| パス | 中身 |
|---|---|
| `build_rooms.py` | GLB を作るスクリプト。寸法と部屋の定義は先頭の定数（`ROOMS` など） |
| `check_rooms.py` | GLB の作りを確かめるスクリプト（ノード名・extras・材質・UV・開口・床・共有の壁・面の重なり） |
| `requirements.txt` | numpy・Pillow・shapely |
| `kit/tools/build_assets.py` | キット v1（MemoryMuseum_Home）の部品ビルダー。**手を加えずにそのまま** 同梱 |
| `kit/config/materials.json` | キット v1 の材質の定義（そのまま。8 種類のうち画像を同梱したのは下の 3 種類だけ） |
| `kit/assets/textures/` | 使う画像だけ：`plaster_*`（壁）、`oak_*`（幅木・枠・柱）、`oak_floor_*`（床）。各 base / normal / orm |
| `kit/THIRD_PARTY_NOTICES.md` | キットのライセンスの注記（そのまま） |

キットの家具や Three.js の同梱版（vendor）は入れていません。

## キット v1 から使っているもの・変えたところ

使っているもの：形の関数（`bevel_box`・`arch_band`・`merge`・`matrix`）、幅木・笠木・回り縁・蛇腹・開口の枠とアーチ・角の柱の寸法、
材質（`Wall_Plaster`・`Floor_Oak`・`Trim_Oak`・`Foundation`）とテクスチャ、GLB の書き出し（`Writer`）。

キットの `room_instances()` はそのまま使わず、同じ寸法で並べ直しています。理由：

- キットの開口（`portal_arch_3m`）は、壁が 1 つのメッシュ（role `wall`）、枠が `trim` で、手前の壁のカット（`wall_upper`・`trim_upper` を隠す）と壁紙の切り替え（`wall_lower`・`wall_upper` を差し替える）に合わない。→ 壁・枠・アーチを高さ 0.92 m で上下に分けた
- 1 m ごとの部品を並べるので、1 部屋で 300 回ほど描画が分かれる。→ 1 辺の壁を役割ごとに 1 メッシュにまとめた（hub 64 メッシュ、6×6 の部屋 29 メッシュ）
- 外の角に 0.24 m 角の切れ目がある。柱と柱頭の上面、幅木どうし（角で交差）など、同じ高さの面が重なってちらつく。→ 南北の壁を外の角まで伸ばし、東西の壁と幅木は南北の壁・幅木の面で止めた。柱は 3.18 m にして、柱の端を足と柱頭の中に収めた
- 開いた側（hub の壁と接する側）の考えが無い

ほかに変えたところ：壁本体は角を丸めない箱（継ぎ目に溝を作らない）、床は 1 部屋 1 枚（`home-empty.glb` と同じ）、
開口の真鍮の縁（`Metal_Brass`）は入れない（材質を 4 つに保つ）、壁の下に土台（`foundation`）を入れて外から見たときのすき間をなくした。
hub の共有の壁（西・東・北）は厚さの半分で分け、隣の部屋から見える側に `extras.faceRoom` を付けた（隣の部屋の壁紙を当てられるように）。

## 本番の GLB に置き換えるとき

1. docs/house-assets.md の仕様で作ってもらう
2. `python3 tools/home-rooms/check_rooms.py <納品のフォルダ>` で確かめる（開発用だけの extras `devShell` は `false` か無しでよい）
3. `backend/static/models/rooms/` の同じ名前のファイルを置き換える
