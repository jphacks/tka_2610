# 受信サーバー（Mac 側）

iPhone の Memoria Capture から、同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）で撮影セッションを受け取ります。Python 3.9 以上の標準ライブラリだけで動きます（pip は不要）。外部のクラウドには何も送りません。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

**受け付けるのは同じネットワークの中からの接続だけです。** 既定では、ループバック・プライベートアドレス（10/8・172.16/12・192.168/16）・リンクローカル（169.254/16・fe80::/10）・IPv6 の ULA（fc00::/7）からの接続だけを受け付け、それ以外（公開 IP アドレス。100.64/10 の CGNAT も含む）からの接続は何も読まず・何も返さずに切って、`[拒否] 外部アドレス <IP> …` を 1 行記録します。通信は暗号化しない HTTP なので、写真をインターネットに流さないためです。詳しくは [docs/transfer-protocol.md](../docs/transfer-protocol.md) の「同じネットワークの中だけ」。

## 起動

```sh
python3 receiver/memoria_receiver.py            # serve と同じ。ポート 8765、保存先は captures/
python3 receiver/memoria_receiver.py serve --port 8765 --data-dir ~/memoria-captures
```

| オプション | 意味 |
|---|---|
| `--port` | 待ち受けるポート（既定 8765） |
| `--host` | 待ち受けるアドレス（既定 `0.0.0.0`） |
| `--data-dir` | 保存先（既定は `capture/captures/`） |
| `--no-bonjour` | Bonjour で広告しない |
| `--allow-remote` | **例外用。** 同じネットワークの外（公開 IP アドレス）からの接続も受け付ける。通信は暗号化されないので、起動時に警告を出す。ふだんは使わない |
| `--reset-code` | ペアリングコードを作り直す |
| `--fail-put-every N` | **テスト専用。** N 回に 1 回 PUT を 500 で失敗させ、iPhone の再送を確かめる（環境変数 `MEMORIA_FAIL_PUT_EVERY` でも可）。ふだんは使わない |

起動すると、ペアリングコード（6 桁）、`http://<IP>:<port>` の URL、保存先、Bonjour の状態を表示します。止めるときは Ctrl-C。

URL には同じネットワークのアドレス（プライベート・リンクローカル）だけを出します。Mac に LAN のアドレスが無く、公開 IP アドレスだけのとき（大学や集合住宅の回線などで Mac に公開アドレスが直接付くとき）は、`[注意]` を表示します。そのネットワークでは iPhone からつながらないので、iPhone と Mac を同じ LAN の Wi-Fi につなぐか、USB ケーブル・インターネット共有でつないでください（リンクローカルの URL は「USB ケーブルなどで直接つないだとき」と書いて出します）。

初めて起動したとき、macOS が「python3 への受信接続を許可しますか」と聞くことがあります。**許可してください**（拒否すると iPhone からつながりません。あとから システム設定 → ネットワーク → ファイアウォール で変えられます）。

## iPhone からつなぐ

1. Mac と iPhone を同じネットワーク（自宅の Wi-Fi・USB ケーブル・iPhone のインターネット共有）につなぎ、受信サーバーを起動する。
2. iPhone のアプリの送信先の一覧に Mac の名前が出る（Bonjour `_memoriacap._tcp`）。出ないときは、起動時に表示された `http://<IP>:<port>` を手で入れる。
3. 起動時に表示されたペアリングコードを入れる。コードは `captures/.receiver.json` に保存され、次の起動でも同じです。

iPhone のアプリも、送り先が公開 IP アドレス（名前なら、引いたアドレスのどれか 1 つでも公開アドレス）のときは送りません。

通信の決まりは [docs/transfer-protocol.md](../docs/transfer-protocol.md) にあります。

## 受け取ったデータ

- 完成したセッションは `captures/sessions/<sessionId>/` だけです。`incoming/` は転送の途中なので使いません。
- フォルダの読み方は、受信サーバーが書く `captures/README.md` にあります。形は [docs/data-format.md](../docs/data-format.md)。
- 平面の作品（session.json の `workKind` が `flat`）のセッションには、マスクの代わりに `rectified/<photoId>.jpg`（遠近を直した画像。作れたときだけ）が入ります。受信サーバーは `rectified/<UUID>.jpg` の path を受け付け、`photos[].flat` の形と `rectified.file` が manifest にあるかを確かめます。
- 向きで案内した立体のセッション（session.json の `guidance` が `heading`）は、基準の `basePointWorld` が null のことがあります（机の面が分からないとき）。受信サーバーは `guidance` の値と、`referenceFrames[].heading`（撮ったあとに求めた中心・大きさ）の形を確かめます。`index.json` の各セッションに `guidance`（立体は `heading` か `baseCylinder`。無いセッションは `baseCylinder`、平面は null）が入ります。
- 撮る人が選んだ・入力した大きさ（session.json の `declaredSize`。平面は一覧から選んだ紙 `sheet`、立体は入力した高さ `heightM`）があれば、受信サーバーは形と値の範囲（紙の辺 0.01〜3 m で長い辺 ≥ 短い辺、高さ 0.005〜3 m）を確かめます。無い・null のセッションもそのまま受け付けます。`show` は「選んだ大きさ」の行に出します。
- 自由に撮った立体のセッション（session.json の `guidance` が `free`）は、撮る方向の一覧が `free`（方向は 0 個）で、基準もマスクもありません。受信サーバーは、方向が 0 個の一覧を `guidance` が `free` のときだけ認め、`free` のときは一覧が `id: "free"`・`targets: []` であることを確かめます。`list` の種類は「立体・自由」です。紙の大きさの「その他」（`declaredSize.sheet.id` が `custom`）は「その他」と表示します。
- 一覧と中身の確認（`list` に種類「立体・平面」の列（向きで案内した立体は「立体・向き」）、`show` に種類と案内のしかた、向きで案内した基準なら求めた中心（線の外れ）・机の面・おおよその大きさと写真ごとの向き、平面の作品なら写真ごとの用紙・実寸・補正した画像の有無が出ます）:

```sh
python3 receiver/memoria_receiver.py list
python3 receiver/memoria_receiver.py show <sessionId の先頭>
```

## AI ツール向けの入力（`captures/for_claude/`）

Claude Code などの AI ツールで作品の 3D モデルを作るときの入口は **`captures/for_claude/<sessionId>/brief.md`** です。向きをそろえて切り抜いた代表の写真（`views/`）、一覧の画像（`overview.jpg`）、visual hull で測った実寸（`measurements.json`）、粗い形（`hull.obj`）が入っています。平面の作品は、まっすぐにした絵（`views/artwork.jpg`）と紙の実寸だけです。作り方と中身は [tools/claude-pack/README.md](../tools/claude-pack/README.md)。

- 受信サーバーは、セッションを受け取る（commit が完了する）たびに `tools/claude-pack/.build/release/memoria-pack` があれば裏で動かします。受信の応答は待たせず、失敗しても受信には影響しません（ログに `[警告] for_claude/ を作れませんでした…` を 1 行）。成功すると `[for_claude] …` を 1 行出します。
- ビルドしていないときは、最初の受信で一度だけ作り方を表示します：`cd tools/claude-pack && swift build -c release`。
- 同じセッションをもう一度 commit しても（すでに完了している）作り直しません。送り直して manifestHash が変わると作り直します。
- `for_claude/` は `sessions/` から作った派生データです。消しても `memoria-pack <sessionId の先頭>` で作り直せます。
- 画像を Claude などのクラウドのツールに渡すことは外部への送信です。するかどうかはユーザーが決めます。

## テスト

```sh
cd receiver && python3 -m unittest -v
# capture/ からなら
python3 -m unittest discover -s receiver/tests -v
```

サーバーを同じプロセスで空いているポートに立て、一時フォルダに受け取ります（Bonjour は使いません）。`sips` が無い環境では、回転したプレビューのテストだけ飛ばします。`for_claude/` を作る処理は、本物の `memoria-pack` の代わりに小さなシェルスクリプトで確かめます（ほかのテストでは動かさない）。
