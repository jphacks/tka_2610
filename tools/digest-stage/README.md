# シアターの舞台のテクスチャ

「期間をえらんで振り返る」シアター（`/map/theater`）の舞台に使う家・木・低木・丘・地面・空の絵と、その輪郭を作るスクリプトです。

- 絵はすべて `generate_stage_textures.py` の手続きで描きます。外部の画像や写真は使いません。シードが固定なので、何度実行しても同じ結果になります。
- 色は memoria の色（`web/src/styles/tokens.css`）に合わせています。
- 出力は `backend/static/stage/` です。サーバーが `/stage-assets/` で配信します。
  - `textures/*.jpg`：各小物の絵・地面（くり返して貼る）・空・紙の凹凸（法線マップ）
  - `stage.json`：小物ごとの輪郭（0〜1 の多角形、y は上向き）・大きさ（m）・厚み・裏と縁の色。Web はこの輪郭で板を押し出し、表に絵を貼ります（`web/src/three/scenes/theater/stageProps.ts`）。絵と形が同じ数値から作られるので、ずれません。

## 作り直すとき

```sh
cd tools/digest-stage
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python generate_stage_textures.py
```

小物を足すときは、関数を 1 つ書いて `main()` から呼び、`prop(...)` で輪郭と大きさを登録します。Web 側は `stage.json` の `kind`（`house`・`tree`・`shrub`・`hill`）で、どこに置くかを決めます。
