# アトリエの作品 13 点（サンプル）

起動時に `backend/src/seed.rs` がここにある作品をデータベースに登録し、おうちに飾ります。
このフォルダが無ければ、登録は何もせずに終わります。

## 出どころ

- 納品された「MemoryMuseum Atelier / Thirteen more small worlds」キットの 13 点です。
- キットの説明によると、すべてデジタルで新しく作ったオリジナルのサンプルです。実在する子どもの作品のスキャンや、他人の写真から作ったものではありません。
- `title` と `description` はキットの `catalog.json` のまま、`titleJa` もキットのものです。`memo` はこのリポジトリで書き足した短い説明です。

## 中身

| パス | 内容 |
|---|---|
| `catalog.json` | 作品の一覧（`assetId`, `titleJa`, `title`, `description`, `memo`, `category`, `dimensionsMeters`, `model`, `photo`） |
| `models/<assetId>.glb` | 作品の 3D モデル。テクスチャを 1024px 以下に縮めたもの（下の手順） |
| `photos/<assetId>_hero.jpg` | キットの `preview/<assetId>_hero.jpg`。登録に必要な写真として使う |

## モデルの縮め方

キットの GLB はテクスチャが 2048px 中心で、スマホでは重すぎるため、取り込む前に 1 回だけ縮めました。

```sh
npx -y @gltf-transform/cli resize --width 1024 --height 1024 <キットの models/xx.glb> backend/static/atelier/models/xx.glb
```

- 使ったのは `@gltf-transform/cli` 4.5.1 です。縦横比は保ったまま、1024px を超えるテクスチャだけが縮みます。
- 13 点の合計は 116.4 MB から 58.2 MB になりました。
- npm で証明書のエラーが出るときは、`NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem` を付けて実行してください（macOS）。

## 登録のされ方（`seed.rs`）

- 作品の id は `assetId` から決まる UUID（v5）です。何度起動しても同じ id になります。
- まだ無い作品だけを登録します（種類は工作、つくった人は「アトリエ」、作成日は 2026-10-14）。新しく登録した作品は、空いている棚や机の上に自動で飾ります。
- データベースに作品があるのに、この PC に画像やモデルのファイルが無いときは、ここから作り直します（同じデータベースを使う 2 台目の PC 用）。
- 登録した作品を消しても、次に起動すると登録し直されます。要らないときはこのフォルダを消してください。
