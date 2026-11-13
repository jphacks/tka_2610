# 写真から 3D を作る（試験中）

> [!IMPORTANT]
> 手元の PC で試すための機能です。本番（Render）と Cloudflare のテスト環境では使いません（環境変数を入れない）。

作品の詳細の「写真から 3D を作る（試験中）」から、作品の写真と実物の大きさを送ると、サーバーがリポジトリの `generator/` の `kt auto` で 3D モデル（GLB）を作り、作品の 3D を差し替えます。

- **入力側**：このアプリ。作品の写真を撮って登録し、作品の詳細から写真（何枚か）と大きさを送る。または、iPhone の撮影アプリ（`capture/`）で撮って Mac に送った撮影を選ぶ（下の「iPhone で撮った写真から」）
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
   # CAPTURE_DATA_DIR=/path/to/captures       # iPhone で撮った写真の受信フォルダ。既定はリポジトリの capture/captures
   ```

3. 起動のログに `[Generator] enabled: <フォルダ> (timeout 900 s, ai model sonnet, iPhone captures <受信フォルダ>)` と出れば使えます。作品の詳細に「写真から 3D を作る（試験中）」が出ます。

使えるのは、`KT_GENERATOR_ENABLED` が `1` で、フォルダに `kt.sh`（Windows は `kt.ps1`）と `setup.sh` が作った venv の Python（`.venv/bin/python`。Windows は `.venv\Scripts\python.exe`）があるときだけです。

- `KT_GENERATOR_ENABLED` が無いとき：ログは `[Generator] disabled`。今までと何も変わりません（作業のフォルダも作らない）
- `1` なのに準備ができていないとき：ログに理由が出ます（例：`[Generator] disabled: KT_GENERATOR_ENABLED=1 ですが、…/generator/.venv/bin/python がありません (generator/ で setup.sh を実行して venv を作ってください)`）

サーバーは、macOS・Linux では `bash <フォルダ>/kt.sh auto <写真…> --size <cm> --out <出力> --ai-model <モデル>`、Windows では `powershell -NoProfile -ExecutionPolicy Bypass -File <フォルダ>\kt.ps1 auto …` を動かします。

## iPhone で撮った写真から

`capture/`（Memoria Capture。[capture/README.md](../capture/README.md)）の iPhone のアプリで作品のまわりを撮ると、写真の方向と作品の大きさが分かります。その写真を `kt auto` に渡せます。

```
iPhone のアプリ（capture/ios）
  └─ 同じ Wi-Fi で送る ─▶ Mac の受信サーバー（capture/receiver。capture/captures/sessions/<sessionId>/ に置く）
        └─ アプリの作品の詳細で撮影を選ぶ（GET /api/capture/sessions）
              └─ サーバーが写真を 8 枚まで選んでまっすぐにする ─▶ kt auto ─▶ GLB ─▶ 作品の 3D を差し替える
```

1. 受信サーバーを起動する：`cd capture && python3 receiver/memoria_receiver.py serve --port 8766`。**既定のポート 8765 は Katachi Loop Studio の画面（`http://127.0.0.1:8765`。`kt` の `--ui`・`kt viewer` で使う）と同じ**なので、Katachi を同じ Mac で動かすときは `--port` で別の番号にします。
2. iPhone で撮って、送信の画面から Mac へ送る（ペアリングコードは受信サーバーが表示する）。
3. 作品の詳細の「写真をえらんで作る」で「iPhone で撮った写真から」を選び、撮影を選んで「3D を作る」。大きさは撮影の値（高さと直径、cm）が入ります（直せる）。

- 読むのは `CAPTURE_DATA_DIR`（既定はリポジトリの `capture/captures`。受信サーバーの `--data-dir` と同じにする）の `sessions/<sessionId>/` だけです。転送の途中の `incoming/`、送り直す前の `replaced/` は読みません。読めない `session.json` は飛ばし、ログに `[Capture] <フォルダ> を飛ばしました (…)` と出します。
- 大きさ：最後に設定した基準の `referenceFrames[].object`（無ければ上の `object`）から、高さ = `heightM` × 100、直径 = `radiusM` × 200（cm）。
- 写真の選び方（`backend/src/capture.rs` の `select_photos`）：
  - 方向が確定していて（`direction.confirmed`）、置き換え済みでない写真（基準と撮影方向ごとの代表。iPhone の「撮影の進み具合」と同じ決まり）だけを使う。基準が違うと方位を比べられないので、そういう写真がある最後の基準の写真から選ぶ
  - 上から見下ろす写真（仰角 60° 以上）があれば、一番高い 1 枚を入れる。残りは 360° を等分した方位に近い写真（方位の差 ＋ 仰角 20° からの差 × 0.25 が一番小さいもの）
  - 方向の確定した写真が 1 枚も無いときは、撮った順に等しい間隔で選ぶ
- 写真の向き：保存した JPEG はセンサーの向き（横長、EXIF Orientation は 1）なので、`image.displayRotationDegClockwise` だけ時計回りに回して JPEG にしてから渡します。マスク（`masks/`）は使いません（`kt` が自分で切り抜く）。
- `capture/tools/reconstruct`（RealityKit の `PhotogrammetrySession`）は別の道具です。作るのが USDZ で、アプリが使う GLB ではないので、まだつないでいません。

## 画面

作品の詳細の「関連する作品」の上に出ます。`GET /api/generator` が `{"enabled": true}` のときだけで、エラー・404・JSON でない返事（Cloudflare 版には `/api/generator` が無く 404）のときは何も出さず、エラーも出しません（`web/src/api/generator.ts`・`web/src/components/ModelGenerator.tsx`）。

1. 「写真をえらんで作る」で、写真（JPEG・PNG・WebP、1〜8 枚、1 枚 20 MB まで）と大きさ（cm。分かっている長さを 1〜3 つカンマで区切る。順不同）を入れて「3D を作る」。iPhone で撮った撮影があれば（`GET /api/capture/sessions` が空でなければ）、「写真をえらぶ」「iPhone で撮った写真から」を切り替えられます（撮影の名前・撮った日時・枚数を出す。一覧が取れないときは切り替えを出さない）
2. 作っているあいだは「生成中…」とかかった時間を出し、3 秒ごとに様子を聞きます（作っている job の id はこのタブの sessionStorage に覚えるので、ほかの画面へ行って戻っても続きを見られる）
3. できたら作品を取り直し、上の 3D が新しいモデルに変わります（ファイル名が変わるので、古い 3D がキャッシュで残らない）。失敗したら理由を出します

## API

どれも `KT_GENERATOR_ENABLED=1` で準備ができているときだけ使えます（`GET /api/generator` 以外は、使えないとき 404）。項目は snake_case です。

| メソッド | パス | 内容 |
|---|---|---|
| GET | `/api/generator` | `{"enabled": true\|false}`。いつでも使える |
| POST | `/api/artworks/:id/generate` | 3D を作り始める（multipart。`photos` を 1〜8 個（JPEG・PNG・WebP。中身で判定、1 枚 20 MB まで）か、`capture_session`（iPhone の撮影の id。ハイフン付きの UUID だけ）のどちらか 1 つと、`size_cm`（0 より大きく 500 以下の数を 1〜3 個、カンマ区切り。「、」も可。`capture_session` のときは省くと撮影の大きさ））。202 で job（下）を返す。無い作品・無い撮影は 404、ほかの作品を作っている途中は 409、写真や大きさが正しくなければ 400（両方送ったときも）、写真が大きすぎると 413。このルートだけ送信の上限が 161 MB |
| GET | `/api/capture/sessions` | iPhone で撮った撮影の一覧（新しい順）。`session_id`・`title`・`created_at`・`created_label`（「2026年11月9日 11:53」）・`photo_count`・`usable_count`（方向が確定した、置き換え済みでない写真の数）・`size_cm`（`[高さ, 直径]`。分からなければ null）。受信フォルダが無ければ `[]` |
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

- **Cloudflare 版（`cloudflare/`）には、この API がありません。** `/api/generator`・`/api/capture/sessions` は 404 なので、画面には何も出ません。
- `capture/`（iPhone のアプリ・受信サーバー・3D を作るツール）も、手元の PC だけで使います。
- 環境変数を入れなければ、サーバーは今までとまったく同じに動きます（`GET /api/generator` が `{"enabled": false}` を返すだけ）。
