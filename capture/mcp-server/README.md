# MCP サーバー（Claude Code・Codex から撮影データを読む）

受信サーバーが受け取った撮影セッション（`captures/`）を、Claude Code や Codex CLI などの AI エージェントが MCP（Model Context Protocol）で読めるようにするサーバーです。エージェントはセッションの一覧を見て、`brief.md` を読み、写真を見て、自分で 3D モデルを作り、セッションごとの出力フォルダに書き出します。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

- Mac の中だけで動きます（標準入出力でつなぐ stdio サーバー）。サーバー自身は外へ何も送りません。
- ただし、エージェントが写真を見る（`get_view`）と、その画像は Claude などのクラウドの AI に渡ります。これは外部への送信です。写真を見せるのは、ユーザーがその作業を頼んだときだけにしてください（`captures/README.md` の「外部への送信について」と同じ決まりです）。
- 元のセッション（`captures/sessions/`）には書き込みません。転送の途中（`captures/incoming/`）は読みません。ペアリングコードの入った `captures/.receiver.json` も読みません。
- 書き込むのは 2 つのツールだけです：`rebuild_pack`（`memoria-pack` を動かして `captures/for_claude/<sessionId>/` を作り直す）と `output_dir`（`captures/reconstructions/<sessionId>/<label>/` を作る）。

## 流れ

1. ユーザーが iPhone で撮って送る → 受信サーバーがセッションを保存し、`memoria-pack` で `for_claude/<sessionId>/`（AI 向けの入力）を作る。
2. エージェントが `latest_session`（または `list_sessions`）で新しいセッションを見つける。
3. `get_brief` で `brief.md`・実寸・写真の一覧を読む。
4. `get_view` で一覧の画像（`overview`）と各方向の写真を見る。必要なら `get_original_photos` で元の写真とカメラの情報を見る。
5. `output_dir` で出力フォルダを作り、モデル（`model.glb` など）・プレビュー画像・`notes.md` を書き出す。

撮影を頼んでから待つときは、今の時刻（タイムゾーン付き）を覚えておき、`latest_session(received_after=その時刻)` を 10〜20 秒おきに呼びます。1 回の呼び出しはすぐに返ります（待ち続けません）。

## ツール

| ツール | 中身 |
|---|---|
| `list_sessions(limit=20)` | 受け取ったセッションを新しい順に。sessionId・タイトル・作品の種類（`workKind`。`object` は立体、`flat` は平面）・立体の撮り方（`guidance`。`free` は案内なしで自由に撮ったもの（どの写真がどの向きかは記録していない）、`heading` は向きで案内して位置と大きさを撮ったあとに求めたもの、`baseCylinder` は底の中心と円柱を先に決めたもの。平面は null）・撮る人が選んだ・入力した大きさ（`declaredSize`。平面は一覧から選んだ紙 `sheet`、立体は入力した高さ `heightM`。AR で測った値ではなく、測った値・求めた値より優先する。入力していなければ null）・撮影方法（`capturePlan`。`ai5` は正面・右・後ろ・左・真上の 5 枚、`flat1` は真上から 1 枚）・写真の数・受信時刻・パック（`for_claude/`）があるか・そのパス |
| `latest_session(received_after=None)` | 一番新しいセッション。`received_after` より後に受け取ったものが無ければ `status: "nothing_new"` |
| `get_brief(session)` | `brief.md` の本文と、作品の種類（`workKind`）、案内のしかた（`guidance`。`heading` なら大きさは撮ったあとに求めたおおよその値で、`measurements.heading` に下と上の目安・信頼度・中心の線の外れ）、撮る人が選んだ・入力した大きさ（`declaredSize`。立体で高さを入力したときは `next` にも「この高さを優先する」と出る）、実寸（`measurements.json`）、見られる写真の一覧（名前・方位と仰角・ピクセルの大きさ・絶対パス）、撮れていない方向。平面の作品は `flat`（使った写真・紙の四隅など）も |
| `get_view(session, view, max_side=1568)` | 1 枚の写真を画像で返す（長い辺が `max_side` より大きければ縮める）。パスと方向も返す。`view="overview"` で一覧の画像 |
| `get_original_photos(session)` | 元の写真（`sessions/<id>/photos/`）のパスと、写真ごとの方向・カメラの姿勢と内部パラメータ・マスクの状態、平面の作品なら紙の四隅・ARKit の平面で測った実寸・補正した画像（`rectified/`）、`declaredSize`、向きで案内したセッションなら撮ったときの向き（`photos[].heading`）と基準の `heading`（撮ったあとに求めた中心・大きさ）（画像そのものは返さない） |
| `rebuild_pack(session, cutouts=false)` | `memoria-pack` でパックを作り直す（受信サーバーと同じ呼び方に `--force`）。`cutouts=true` で背景を透明にした `views/<名前>_cutout.png` も作る |
| `output_dir(session, label)` | `captures/reconstructions/<sessionId>/<label>/` を作って返す。`label` の `A-Z a-z 0-9 . _ -` 以外の文字は `-` にする |
| `receiver_status()` | 受信サーバーがポート（既定 8765）で待ち受けているか（接続できるかだけを見る。認証の値は送らない）、`captures/` の場所、セッションの数、`memoria-pack` をビルドしてあるか |

- `session` には sessionId 全体か、先頭の数文字（大文字・小文字は問わない）を渡します。あてはまるものが無い・複数あるときは、候補を並べたエラーを返します。
- 結果にはすべて絶対パスが入っています。ファイルを読めるエージェントは、元のファイルを直接開けます。
- 写真の名前（`front`・`top` など）は決め打ちせず、`pack.json` とフォルダにあるものから作ります。`ai5` のパックは背景付きの写真だけ（`hull.obj` なし、実寸は撮影時の円柱の目安）、前の版のパックは `<名前>_cutout.jpg` と `hull.obj` もあります。`get_view` に渡せるのは `get_brief` の一覧にある名前と `overview` だけです。
- **自由に撮った立体**（`guidance` が `free`）のパックは、撮った順の `photo-01`・`photo-02`…（16 枚まで）だけです。`overview` はありません。どの写真が正面・横・後ろ・真上かは記録していないので、写真を見て決めます。大きさは写真から求めず、撮る人が高さを入力したときだけ `measurements.declaredHeight` にあります。
- **平面の作品**（`workKind` が `flat`）のパックは、`artwork`（遠近を直した絵。直せなかったときは写真をまっすぐに回したもの）と、補正したときは `photo`（元の写真）だけです。`overview` はありません。紙の大きさは `measurements.sheet`（`source` が `declared` なら撮る人が一覧から選んだ紙、`measured` なら ARKit の平面で測った値。どちらも無ければ null）。3D の形を作る必要はなく、絵を板や額に貼る形で使えます。
- `get_view` は JPEG を JPEG のまま、透明の PNG（`_cutout.png`）を PNG のまま返します。縮めるのに macOS の `sips` を使います（Pillow などは要りません）。

## 必要なもの

- [uv](https://docs.astral.sh/uv/)（`brew install uv`）。依存（公式の Python MCP SDK `mcp`）は、スクリプトの先頭に書いてあり（PEP 723）、uv が初回に入れます。Python は 3.10 以上で、無ければ uv が用意します。
- パックを作り直すときは、ビルドした `memoria-pack`（`cd tools/claude-pack && swift build -c release`）。

手で起動するときは、`capture/` で次のようにします（MCP のクライアントからつなぐもので、そのままでは何も表示しません。Ctrl-C で止めます）。

```sh
uv run --script mcp-server/memoria_mcp.py
```

## つなぎ方

### Claude Code（tka_2610 で使う）

tka_2610 の一番上の `.mcp.json` に `memoria-capture` として書いてあります（スクリプトの場所は `capture/mcp-server/memoria_mcp.py`）。tka_2610（またはその下のフォルダ）で `claude` を起動すると、初回に使ってよいかを聞かれるので、許可してください。`/mcp` で状態を見られます。

### どのプロジェクトからでも使う（Claude Code と Codex）

```sh
scripts/install-mcp.sh              # 登録する（何度実行しても同じ）
scripts/install-mcp.sh --dry-run    # 実行するコマンドを表示するだけ
scripts/install-mcp.sh --uninstall  # 登録を消す
```

このスクリプトは、依存を先に入れ（`uv sync --script`）、このチェックアウトの絶対パスで次の 2 つを実行します（前の登録があれば消してから足します）。

```sh
claude mcp add --scope user memoria-capture -- <uv のパス> run --script <tka_2610>/capture/mcp-server/memoria_mcp.py
codex mcp add memoria-capture -- <uv のパス> run --script <tka_2610>/capture/mcp-server/memoria_mcp.py
```

チェックアウトを別の場所へ移したときは、もう一度実行してください。

### 撮影データの場所を変える

既定は `capture/captures/` です（起動したフォルダではなく、`memoria_mcp.py` の場所から決めます）。受信サーバーを `--data-dir` で別のフォルダにしているときは、環境変数 `MEMORIA_CAPTURES_DIR` で同じフォルダを指定します（`claude mcp add -e MEMORIA_CAPTURES_DIR=... `、`codex mcp add --env MEMORIA_CAPTURES_DIR=...`）。受信サーバーのポートを変えているときは `MEMORIA_RECEIVER_PORT` も指定します（`receiver_status` だけが使います）。

## 動くかの確認

```sh
python3 -m unittest discover -s mcp-server/tests -v   # 一時フォルダの偽の captures/ で確かめる（MCP SDK は要らない）
claude mcp get memoria-capture                        # Status: ✔ Connected
codex mcp get memoria-capture
```

Claude Code の中では `/mcp` に `memoria-capture` が出て、「receiver_status を呼んで」などと頼むと結果が返ります。

## うまくいかないとき

| 症状 | 確かめること |
|---|---|
| つながらない（Failed to connect） | `uv` が PATH にあるか（`command -v uv`）。`capture/` で `uv run --script mcp-server/memoria_mcp.py` を実行し、エラーが出ないか（標準エラーに `captures: …` と出て待ち続ければ正常） |
| 初回だけ時間切れになる | uv が依存を入れている間に、クライアントの起動の待ち時間（Codex は既定 10 秒）を過ぎた。`uv sync --script mcp-server/memoria_mcp.py` を一度実行してからつなぎ直す。Codex は `~/.codex/config.toml` の `[mcp_servers.memoria-capture]` に `startup_timeout_sec = 30` を足してもよい |
| `has no pack` と出る | 受け取った直後なら数秒待つ。作られないときは `rebuild_pack` |
| `memoria-pack is not built` と出る | `cd tools/claude-pack && swift build -c release` |
| セッションが出てこない | `receiver_status` の `capturesDir` が受信サーバーの保存先と同じか。転送の途中（`incoming/`）のものは出ません |
| `receiverListening` が false | 受信サーバーを起動する（`python3 receiver/memoria_receiver.py`）。ポートを変えているときは `MEMORIA_RECEIVER_PORT` |
| 画像が大きすぎると言われる | `get_view` の `max_side` を小さくする（例 1024）。Claude Code は `MAX_MCP_OUTPUT_TOKENS` で上限を変えられます |

- サーバーのログは標準エラーに出ます（標準出力は MCP の通信だけに使います）。
