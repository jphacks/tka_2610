# iPhone → Mac の転送（protocolVersion 1）

同じネットワークの Mac で `receiver/memoria_receiver.py` を動かし、iPhone から HTTP でファイルを送ります。ZIP は使いません。外部のクラウドには送りません。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

## 同じネットワークの中だけ

子どもの作品の写真を送るので、**転送は同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）の中だけ** にします。HTTP は暗号化しないので、インターネットを通る経路では送りません。iPhone と受信側の両方で確かめます。

同じネットワークとみなすアドレス（両方で同じ。受信側は `memoria_receiver.py` の `LOCAL_NETWORKS`、iPhone は CaptureCore の `LocalNetworkPolicy`）：

| 範囲 | 中身 |
|---|---|
| `127.0.0.0/8`・`::1` | 同じ Mac（ループバック） |
| `10.0.0.0/8`・`172.16.0.0/12`・`192.168.0.0/16` | プライベートなネットワーク（RFC 1918）。iPhone のインターネット共有（Wi-Fi・USB）の `172.20.10.0/28` もここ |
| `169.254.0.0/16`・`fe80::/10` | リンクローカル（USB ケーブルや、ルーターの無い直接の接続） |
| `fc00::/7` | IPv6 の ULA |

ほかはすべて公開アドレスとして扱います。`::ffff:a.b.c.d`（IPv4 を IPv6 で書いたもの）は IPv4 として見ます。`100.64.0.0/10`（携帯会社などの CGNAT、RFC 6598）は **入れません**。携帯会社がたくさんの契約者で共有する範囲で、そこからの接続が同じ LAN とは限らないためです（インターネット共有は 172.20.10.0/28 なので困りません。Tailscale なども 100.64/10 を使いますが、同じネットワークではないので対象外）。

- **受信側**：既定では上の範囲からの接続だけを受け付けます。それ以外からの接続は、何も読まず・何も返さずにすぐ切り（`ThreadingHTTPServer.verify_request`。ハンドラーでももう一度確かめる）、`[拒否] 外部アドレス <IP> …` を 1 行だけ記録します（同じアドレスは 60 秒に 1 回まで）。ペアリングコードの失敗回数による 429 はそのまま。例外のときだけ `--allow-remote` で外からの接続も受け付けます（起動時に、暗号化されないという警告を出す）。
- **受信側の起動時の表示**：接続先 URL には、プライベート・リンクローカルのアドレスだけを出します。Mac に LAN のアドレスが無く公開アドレスだけのとき（大学や集合住宅の回線などで、Mac に公開 IP アドレスが直接付く）は、このネットワークは自宅などの LAN ではないようだ、iPhone を同じ LAN か USB ケーブル・インターネット共有でつないでほしい、公開アドレスからは受け付けない、と表示します。Bonjour の広告は今までどおり（リンクローカルのマルチキャストなので外には出ない）。
- **iPhone**：つなぐ前に毎回、送り先の host を確かめます（`TransferClient` の全部の要求）。IP アドレスの文字なら上の範囲か、`.local` の名前（Bonjour）はそのまま、ほかの名前は引いたアドレスを全部見て、1 つでも公開アドレスなら送らずに「同じネットワーク（自宅の Wi-Fi・USB ケーブル・インターネット共有）の Mac にだけ送れます。公開 IP アドレスには送りません」と出します。アプリにはこれを外す設定はありません。

## 見つけ方・つなぎ方

- 受信側は同じネットワークの中からの接続だけを受け付けます（上の「同じネットワークの中だけ」）。
- 受信側は Bonjour で `_memoriacap._tcp` を広告します（macOS の `dns-sd -R` を使う）。TXT は `host=<LocalHostName>.local`、`port=<番号>`、`pv=1`。
- iPhone は Bonjour で見つけた Mac を一覧に出します。見つからないときは、受信側が起動時に表示する `http://<IP>:<port>` を手で入れられます。
- 受信側は起動時に 6 桁のペアリングコードを表示します（`captures/.receiver.json` に保存し、次の起動でも同じ）。iPhone はすべての要求に `X-Memoria-Token: <コード>` を付けます。違えば 401。

## 手順

ベースは `http://<host>:<port>/api/v1`。応答はすべて JSON。

1. `GET /ping` → `{"service": "memoria-capture-receiver", "protocolVersion": 1, "receiverId": "<uuid>", "name": "<Mac の名前>"}`
2. `POST /sessions/{sessionId}/uploads`、本文 `{"files": [{"path": "session.json", "size": 1234, "sha256": "<hex>"}, …]}`
   - 受信側は manifestHash を計算します：`path` で並べた各行 `"{path}\t{size}\t{sha256}\n"` をつなげた UTF-8 の SHA-256（hex）。
   - 同じ sessionId・同じ manifestHash の完了済みセッションがあれば `{"status": "alreadyComplete", "manifestHash": …}`（200）。iPhone は転送完了として扱います。
   - そうでなければ `{"status": "uploading", "uploadId": "<manifestHash>", "missing": ["photos/….jpg", …]}`。途中まで届いているファイル（大きさとハッシュが合うもの）は `missing` に入りません（再送で同じファイルを送り直さない）。
3. `PUT /sessions/{sessionId}/uploads/{uploadId}/files/{path}`、本文はファイルそのもの、ヘッダー `X-Content-SHA256: <hex>`
   - manifest に無い path は 409、大きさかハッシュが合わなければ 422（書いたものは捨てる）。合えば `{"status": "stored"}`、すでにあれば `{"status": "alreadyStored"}`。
4. `POST /sessions/{sessionId}/uploads/{uploadId}/commit`
   - 全ファイルがそろい、ハッシュが合い、`session.json` が読めて（`schema`・`schemaVersion` 1・`sessionId` が一致、`workKind` があれば `object`・`flat` のどちらか）、`photos[].image.file` と、`mask.status` が `candidate`・`confirmed` の `mask.file` と、`photos[].flat.rectified.file`（`rectified/<photoId>.jpg`）がすべて manifest にあるときだけ完了。`photos[].flat` の四隅（`corners`）と実寸（`size`）は形も確かめます。
   - 完了：`{"status": "complete", "manifestHash": …, "path": "<Mac 上のフォルダ>"}`（200）。もう一度 commit しても同じ応答。
   - 足りない：409 `{"status": "incomplete", "missing": […]}`。session.json がおかしい：422 `{"status": "invalid", "errors": […]}`。
5. `GET /sessions/{sessionId}` → `{"status": "complete", "manifestHash": …}` か 404 `{"status": "notFound"}`

## path と ID

- sessionId は UUID（`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`）。
- path は `session.json`、`photos/<UUID>.jpg`、`masks/<UUID>.png`、`rectified/<UUID>.jpg`（平面の作品の、遠近を直した画像）だけ。ほかは 400。
- `rectified/` は後から足した path です。これより前の受信サーバーは 400 を返すので、平面の作品を送るときは受信サーバーも新しくしてください（立体の作品は前の受信サーバーにも送れます）。

## Mac 側のフォルダ（既定は `capture/captures/`、`--data-dir` で変更）

```
captures/
  README.md                       このフォルダの読み方（受信側が書く）
  index.json                      完了したセッションの一覧（受信側が書き直す）
  sessions/<sessionId>/           完了したセッションだけ。中身は data-format.md の形
    session.json  photos/  masks/  rectified/（平面の作品だけ）
    _receipt.json                 {"complete": true, "manifestHash", "receivedAt", "files": [...]}
    upright/photos/*.jpg          表示用にまっすぐに回したコピー（K は合わない。sips があるときだけ）
    upright/masks/*.png
  for_claude/<sessionId>/         AI ツール向けの入力（受信のあとに tools/claude-pack の memoria-pack が作る派生データ。ビルドしてあるときだけ）
  incoming/<sessionId>/<uploadId>/  転送中（生成用のデータとして使わない）
  replaced/<sessionId>-<時刻>/      同じセッションを送り直したときの前の版
```

- `sessions/` には完了したものしか置きません（staging で全部確かめてから、フォルダごと rename）。
- 撮り直してから送り直すと manifestHash が変わるので、新しい版として受け取り、前の版は `replaced/` に移します。
