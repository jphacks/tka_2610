# アトリエの作品 33 点（サンプル）

起動時に `backend/src/seed.rs` がここにある作品をデータベースに登録し、おうちに飾ります。
このフォルダが無ければ、登録は何もせずに終わります。

## 出どころ

- 納品された 2 つのキットの作品です。
  - `06`〜`18` の 13 点：「MemoryMuseum Atelier / Thirteen more small worlds」
  - `19`〜`38` の 20 点：「MemoryMuseum Atelier20 / Twenty new handmade worlds」（粘土・塗料・木の棒・アルミ箔・薄紙の素材が増えた版）
- キットの説明によると、すべてデジタルで新しく作ったオリジナルのサンプルです。実在する子どもの作品のスキャンや、他人の写真から作ったものではありません。
- `title` と `description` はキットの `catalog.json` のまま、`titleJa` もキットのものです。`memo` はこのリポジトリで書き足した短い説明です。

## 中身

| パス | 内容 |
|---|---|
| `catalog.json` | 作品の一覧（`assetId`, `titleJa`, `title`, `description`, `memo`, `madeOn`, `category`, `dimensionsMeters`, `model`, `photo`） |
| `models/<assetId>.glb` | 作品の 3D モデル。テクスチャを 1024px 以下に縮めたもの（下の手順） |
| `photos/<assetId>_hero.jpg` | キットの `preview/<assetId>_hero.jpg`（20 点のキットは `_hero.png` を `sips` で JPEG の品質 88 にしたもの）。登録に必要な写真として使う |

## モデルの縮め方

キットの GLB はテクスチャが 2048px 中心で、スマホでは重すぎるため、取り込む前に 1 回だけ縮めました。

```sh
npx -y @gltf-transform/cli resize --width 1024 --height 1024 <キットの models/xx.glb> backend/static/atelier/models/xx.glb
```

- 使ったのは `@gltf-transform/cli` 4.5.1 です。縦横比は保ったまま、1024px を超えるテクスチャだけが縮みます。
- 最初の 13 点の合計は 116.4 MB から 58.2 MB になりました。
- 20 点のキットは、もとから 1024px のテクスチャが多く、189 MB から 127 MB です（作品 1 点に 20 枚以上の画像があるため）。合計は 33 点で 183 MB です。
- npm で証明書のエラーが出るときは、`NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem` を付けて実行してください（macOS）。

## 登録のされ方（`seed.rs`）

- 作品の id は `assetId` から決まる UUID（v5）です。何度起動しても同じ id になります。
- まだ無い作品だけを登録します（種類は工作、つくった人は「アトリエ」、作成日は `catalog.json` の `madeOn`）。新しく登録した作品は、作ったときの年齢のおへやの空いている棚や机の上に自動で飾ります。その年齢のどのおへやもいっぱいなら、いちばん上におへやを足して飾ります（`home_api.rs` の `place_in_age_adding_floors`。デモの誕生日では 4さいが 19 点になり、2 階ができます）。
- 作成日（`madeOn`）は、去年（2025 年）と今年（2026 年）の休みの日（土日・祝日）に、作品の季節に合わせて散らしてあります（ちょうちょは春、海や帆船は夏休み、太陽系は冬休み、カメラは敬老の日など）。`madeOn` はこのリポジトリで書き足した値です。
- 以前の版は 13 点とも作成日を 2026-10-14 にしていました。その日付のままの作品は、起動時に `madeOn` の日付に直します（ログの `redated`）。画面で作成日を変えた作品は触りません。
- データベースに作品があるのに、この PC に画像やモデルのファイルが無いときは、ここから作り直します（同じデータベースを使う 2 台目の PC 用）。
- 登録した作品を消しても、次に起動すると登録し直されます。要らないときはこのフォルダを消してください。
