# 内装セット（finish-pack）

壁紙 5 種と床材 5 種の PBR テクスチャです。`catalog.json` の `materials`（キーは素材の id）と `themes`（6 種）から使います。
配信は `/home-assets/textures/finish-pack/<素材 id>/`。

## 出どころ

- 素材セット `MemoryHome_Materials_v1`（pack id `memoryhome-materials-01`）の `materials/<id>/` から、`basecolor.jpg`・`normal.png`・`orm.png` の 30 枚をそのまま入れました（サムネイルは使わないので入れていません）。
- セットの `THIRD_PARTY_NOTICES.md` によると、画像はこのプロジェクトのためにプログラムで作ったもので、市販のスキャン・外部の写真・画像生成のピクセルは含みません（固定の乱数シード）。第三者のライセンスがかかるのはセットの確認用ビューアーに入っている Three.js（MIT）だけで、ここには入れていません。
- セットの `checksums.sha256` と同じ値であることを確かめて入れました（`SHA256SUMS`。`shasum -a 256 -c SHA256SUMS` で確かめられます）。

## 作り

| 種類 | id | 1 枚の大きさ（`tileMeters`） |
|---|---|---|
| 壁 | `nordic_chalk`・`sage_limewash`・`mushroom_limewash`・`warm_cream` | 1 × 1 m |
| 壁 | `soft_brick` | 1 × 0.6 m |
| 床 | `white_oak`・`pale_ash`・`warm_walnut`・`carrara_marble`・`nero_marble` | 2 × 2 m |

- どれも 1024 × 1024。色の画像（`basecolor.jpg`）は sRGB で、仕上がりの色そのもの（材質の色は白のまま掛ける。白壁 `plaster` の色の補正は掛けない）。
- `normal.png` は OpenGL 形式（+Y）、`orm.png` は R = 遮蔽（すべて 255）・G = 粗さ・B = 金属（すべて 0）。どちらもリニア。
- 当て方は `web/src/three/scenes/home/theme.ts`（repeat・offset は `tileMeters` から計算する）。確かめるのは `cd web && npm run check:theme`。

画像を差し替えるときは、同じ名前・同じ大きさ（1024 px 以下）にして、`SHA256SUMS` を作り直してください。
