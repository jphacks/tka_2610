# 写真から 3D を作る（試験中）

> [!IMPORTANT]
> 手元の PC で試すための機能です。本番（Render）と Cloudflare のテスト環境では使いません（環境変数を入れない）。

作品の詳細の「写真から 3D を作る（試験中）」から、作品の写真と実物の大きさを送ると、サーバーがリポジトリの `generator/` の `kt auto` で 3D モデル（GLB）を作り、作品の 3D を差し替えます。

- **入力側**：このアプリ。作品の写真を撮って登録し、作品の詳細から写真（何枚か）と大きさを送る
- **生成側**：`generator/`（Python の `kt`。もとは `kobadaidesu/3d_generator`）。写真を測って、AI（Claude Code）に作り方（箱・平面・ボトル・回転体・形の生成）を選ばせ、`model.glb` を作る。使い方と準備は [generator/README.md](../generator/README.md)

作った GLB は、編集の画面で GLB をアップロードしたときと同じように扱います（`model_kind` が `custom`、寸法は GLB から測り直す）。作品の写真とサムネイルはそのままです。

## 手元で使う

1. `generator/` の準備をする（[generator/README.md](../generator/README.md) の「準備」）。Katachi Loop Studio 0.5.0 を展開して `./setup.sh` を実行し、`generator/.venv` を作ります。曲面の物も作るなら `./setup_gen.sh` も（重みは約 7 GB、GPU を使う）。`kt auto` は `claude` コマンド（Claude Code にログインしたもの）も使います。
2. `.env` に次を足して、サーバーを起動し直します。

   ```bash
   KT_GENERATOR_ENABLED=1
   # KT_GENERATOR_DIR=/path/to/generator     # 既定はリポジトリの generator/（ビルドした場所から辿る）
   # KT_GENERATOR_TIMEOUT_SECS=900            # 1 回の生成の上限（秒）
   # KT_GENERATOR_AI_MODEL=sonnet             # kt auto の --ai-model
   ```

3. 起動のログに `[Generator] enabled: <フォルダ> (timeout 900 s, ai model sonnet)` と出れば使えます。作品の詳細に「写真から 3D を作る（試験中）」が出ます。

使えるのは、`KT_GENERATOR_ENABLED` が `1` で、フォルダに `kt.sh`（Windows は `kt.ps1`）と `setup.sh` が作った venv の Python（`.venv/bin/python`。Windows は `.venv\Scripts\python.exe`）があるときだけです。

- `KT_GENERATOR_ENABLED` が無いとき：ログは `[Generator] disabled`。今までと何も変わりません（作業のフォルダも作らない）
- `1` なのに準備ができていないとき：ログに理由が出ます（例：`[Generator] disabled: KT_GENERATOR_ENABLED=1 ですが、…/generator/.venv/bin/python がありません (generator/ で setup.sh を実行して venv を作ってください)`）

サーバーは、macOS・Linux では `bash <フォルダ>/kt.sh auto <写真…> --size <cm> --out <出力> --ai-model <モデル>`、Windows では `powershell -NoProfile -ExecutionPolicy Bypass -File <フォルダ>\kt.ps1 auto …` を動かします。

## 画面

作品の詳細の「関連する作品」の上に出ます。`GET /api/generator` が `{"enabled": true}` のときだけで、エラー・404・JSON でない返事（Cloudflare 版には `/api/generator` が無く 404）のときは何も出さず、エラーも出しません（`web/src/api/generator.ts`・`web/src/components/ModelGenerator.tsx`）。

1. 「写真をえらんで作る」で、写真（JPEG・PNG・WebP、1〜8 枚、1 枚 20 MB まで）と大きさ（cm。分かっている長さを 1〜3 つカンマで区切る。順不同）を入れて「3D を作る」
2. 作っているあいだは「生成中…」とかかった時間を出し、3 秒ごとに様子を聞きます（作っている job の id はこのタブの sessionStorage に覚えるので、ほかの画面へ行って戻っても続きを見られる）
3. できたら作品を取り直し、上の 3D が新しいモデルに変わります（ファイル名が変わるので、古い 3D がキャッシュで残らない）。失敗したら理由を出します

## API

どれも `KT_GENERATOR_ENABLED=1` で準備ができているときだけ使えます（`GET /api/generator` 以外は、使えないとき 404）。項目は snake_case です。

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/generator` | `{"enabled": true\|false}`。いつでも使える |
| POST | `/api/artworks/:id/generate` | 3D を作り始める（multipart。`photos` を 1〜8 個（JPEG・PNG・WebP。中身で判定、1 枚 20 MB まで）、`size_cm`（0 より大きく 500 以下の数を 1〜3 個、カンマ区切り。「、」も可））。202 で job（下）を返す。無い作品は 404、ほかの作品を作っている途中は 409、写真や大きさが正しくなければ 400、写真が大きすぎると 413。このルートだけ送信の上限が 161 MB |
| GET | `/api/generator/jobs/:job_id` | job の様子 `{"job_id", "artwork_id", "status", "error", "elapsed_secs"}`。`status` は `running`・`done`・`failed`、`error` は失敗したときの短い説明（日本語）、`elapsed_secs` は始めてからの秒数（終わった job は終わるまで）。知らない job は 404 |

## 仕組み

`backend/src/generator.rs` にまとまっています。

- 設定は起動のときに 1 回だけ環境変数から読みます（`config_from`）。
- 受け取った写真は OS の一時フォルダの `memoria-generator/<job の id>/photos/`（`/media` で配信されないよう、`MEDIA_DIR` には置かない） に置き、`kt auto` の出力は同じフォルダの `out/` に出します。終わったら（成功しても失敗しても）フォルダごと消します。起動のときに残っていれば消します（使うときだけ）。
- `kt auto` は `tokio::process` で、別のプロセスグループにして動かします。上限の時間（`KT_GENERATOR_TIMEOUT_SECS`）を過ぎると、`kt` が起こした子のプロセス（`claude`・形の生成）ごと止めます。失敗したときは、サーバーのログに `kt` の出力の最後の 20 行を出し、画面には短い説明だけを返します。
- できた `out/model.glb` を `glb::validate_glb` で確かめ、`artworks::replace_model` で作品の 3D を差し替えます（新しい名前のファイルを書いてから行を書き換え、古い GLB を消す。寸法は `glb::measure_glb` で測る）。飾っている作品は、そのあと `home_api::reconcile` で置き直します（大きさが変わって今の場所に収まらなくなったら、同じ年齢のおへやの空いている所へ。編集の画面でモデルを作り直したときも同じ）。

## 限界

- **job はメモリにだけあります。** サーバーを止めると、作っている途中の job も記録も消えます（画面には「生成の様子が分からなくなりました」と出る）。DB は変えていません（マイグレーションなし）。終わった job は新しい 20 個だけ覚えています。
- **同時に作るのは 1 つだけです**（GPU を使うため）。ほかの作品を作っている途中は 409 です。
- **完全ではありません。** 振り分けや素材は AI の判断なので、実行のたびに少し変わります。写真の撮り方で結果が大きく変わります（[generator/README.md](../generator/README.md) の「撮影のコツ」）。差し替える前の 3D には戻せません（作った GLB は `custom` なので、編集で写真を選び直しても 3D はそのまま。もう一度作るか、編集で別の GLB を渡す）。
- 作った GLB のテクスチャは縮めていません（作品の GLB は 1024px 以下が決まりなので、スマホで重いことがあります。AGENTS.md）。
- 時間は、箱・平面・ボトルで 1 分前後、形の生成で 3 分前後です（GPU による）。

## 本番では使わない

- **本番（Render）に `KT_GENERATOR_ENABLED` を入れないでください。** 入れ物（`Dockerfile`）には Python も `generator/` も入りません（`.dockerignore` で送らない）。入れても venv が無いので `disabled` になりますが、入れないのが決まりです。
- **Cloudflare 版（`cloudflare/`）には、この API がありません。** `/api/generator` は 404 なので、画面には何も出ません。
- 環境変数を入れなければ、サーバーは今までとまったく同じに動きます（`GET /api/generator` が `{"enabled": false}` を返すだけ）。
