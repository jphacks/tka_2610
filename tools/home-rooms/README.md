# tools/home-rooms — 家の建物（開発用シェル）

> [!NOTE]
> ここで作る GLB は **開発用** です。アプリの部屋ごとの建物を先に作って試すためのもので、
> 本番品質の GLB は別に納品してもらい、同じファイル名で置き換えます。
> 今の家は中央のリビング（`hub`）の 1 部屋だけで、開口（出入口）はありません。以前の左・右・前の部屋（`left`・`right`・`front`）は消しました。本番の GLB の仕様は [docs/house-assets.md](../../docs/house-assets.md) にあります。

## できるもの

`backend/static/models/rooms/` に GLB を書き出します。今は `hub.glb` の 1 つだけです。部屋の中心を原点にしていて、アプリが部屋の origin へ平行移動して置きます（回転なし）。

| ファイル | 部屋 | origin (x, z) | 内寸 | 壁 | 大きさ |
|---|---|---|---|---|---|
| `hub.glb` | 中央のリビング | (0, 0) | 10 × 10 m | 4 面。開口なし（高さ 4.2 m（キットは 3.2 m）、厚さ 0.24 m） | 約 2.34 MB（メッシュのノード 34） |

ノード名・extras・材質の決まりは docs/house-assets.md の「ノードと extras」を見てください。

部屋を戻すときは、`build_rooms.py` の `ROOMS`（部屋と、hub の `doors` に開口の向き）と `HUB_WALL_AT_OPEN`、`check_rooms.py` の `EXPECT`・`ORIGINS`・`DOOR_TO_ROOM`・`HUB_WALL_AT_OPEN` に部屋を足します（以前の 4 部屋の値は git の履歴にあります）。4 部屋のころは、`left`（(−9.24, 0)、東を開ける）・`right`（(9.24, 0)、西を開ける）・`front`（(0, −9.24)、−Z 側。南を開ける）の 8 × 8 m の 3 部屋が hub の壁を共有し（通路なし）、hub の西・東・北の中央に開口（有効幅 2.10 m・高さ 2.60 m）がありました。開口の下の帯（壁の厚さ 0.24 m）の床は `hub.glb` に入れます。バックエンドの `ROOM_DEFS` など、アプリ側も合わせて変えます（[AGENTS.md](../../AGENTS.md) の「構成」）。

## 作り直す

Python 3.10 以上が要ります（このリポジトリでは Homebrew の python3.12 で確認）。`.venv` は git に入りません。

```sh
python3.12 -m venv tools/home-rooms/.venv
tools/home-rooms/.venv/bin/pip install -r tools/home-rooms/requirements.txt
tools/home-rooms/.venv/bin/python tools/home-rooms/build_rooms.py
python3 tools/home-rooms/check_rooms.py
```

- `build_rooms.py` は 2 秒ほどで GLB（今は `hub.glb`）を上書きします。同じ入力なら毎回同じバイト列になります。
- `check_rooms.py` は Python の標準ライブラリだけで動きます（venv は要りません）。最後に `ALL CHECKS PASSED` と出れば OK です。今は hub だけを調べ、開口・床のつながり・開いた側・共有の壁の検査は、隣の部屋が無いので飛ばします。
  別のフォルダの GLB（納品された本番の GLB など）も `python3 tools/home-rooms/check_rooms.py <フォルダ>` で同じように調べられます。

## 中身

| パス | 中身 |
|---|---|
| `build_rooms.py` | GLB を作るスクリプト。寸法と部屋の定義は先頭の定数（`ROOMS` など） |
| `check_rooms.py` | GLB の作りを確かめるスクリプト（ノード名・extras・材質・UV・面の重なり。隣の部屋があるときは開口・床・共有の壁も） |
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
- 1 m ごとの部品を並べるので、1 部屋で 300 回ほど描画が分かれる。→ 1 辺の壁を役割ごとに 1 メッシュにまとめた（今の hub は 34。4 部屋のころは hub 64、左・右・前の部屋 29）
- 外の角に 0.24 m 角の切れ目がある。柱と柱頭の上面、幅木どうし（角で交差）など、同じ高さの面が重なってちらつく。→ 南北の壁を外の角まで伸ばし、東西の壁と幅木は南北の壁・幅木の面で止めた。柱は壁より 2 cm 低く（4.18 m）して、柱の端を足と柱頭の中に収めた
- 開いた側（hub の壁と接する側）の考えが無い（部屋を戻すときに使う）

ほかに変えたところ：壁本体は角を丸めない箱（継ぎ目に溝を作らない）、床は 1 部屋 1 枚（`home-empty.glb` と同じ）、
開口の真鍮の縁（`Metal_Brass`）は入れない（材質を 4 つに保つ）、壁の下に土台（`foundation`）を入れて外から見たときのすき間をなくした。
隣の部屋があるときは、hub の共有の壁を厚さの半分で分け、隣の部屋から見える側に `extras.faceRoom` を付ける（隣の部屋の壁紙を当てられるように。今の hub には共有の壁が無いので分けない）。

## 本番の GLB に置き換えるとき

1. docs/house-assets.md の仕様で作ってもらう
2. `python3 tools/home-rooms/check_rooms.py <納品のフォルダ>` で確かめる（開発用だけの extras `devShell` は `false` か無しでよい）
3. `backend/static/models/rooms/` の同じ名前のファイルを置き換える
