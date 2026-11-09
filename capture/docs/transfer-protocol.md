# iPhone → Mac の転送（protocolVersion 1）

同じ Wi-Fi の Mac で `receiver/memoria_receiver.py` を動かし、iPhone から HTTP でファイルを送ります。ZIP は使いません。外部のクラウドには送りません。

## 見つけ方・つなぎ方

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
   - 全ファイルがそろい、ハッシュが合い、`session.json` が読めて（`schema`・`schemaVersion` 1・`sessionId` が一致）、`photos[].image.file` と、`mask.status` が `candidate`・`confirmed` の `mask.file` がすべて manifest にあるときだけ完了。
   - 完了：`{"status": "complete", "manifestHash": …, "path": "<Mac 上のフォルダ>"}`（200）。もう一度 commit しても同じ応答。
   - 足りない：409 `{"status": "incomplete", "missing": […]}`。session.json がおかしい：422 `{"status": "invalid", "errors": […]}`。
5. `GET /sessions/{sessionId}` → `{"status": "complete", "manifestHash": …}` か 404 `{"status": "notFound"}`

## path と ID

- sessionId は UUID（`^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$`）。
- path は `session.json`、`photos/<UUID>.jpg`、`masks/<UUID>.png` だけ。ほかは 400。

## Mac 側のフォルダ（既定は `capture/captures/`、`--data-dir` で変更）

```
captures/
  README.md                       このフォルダの読み方（受信側が書く）
  index.json                      完了したセッションの一覧（受信側が書き直す）
  sessions/<sessionId>/           完了したセッションだけ。中身は data-format.md の形
    session.json  photos/  masks/
    _receipt.json                 {"complete": true, "manifestHash", "receivedAt", "files": [...]}
    upright/photos/*.jpg          表示用にまっすぐに回したコピー（K は合わない。sips があるときだけ）
    upright/masks/*.png
  incoming/<sessionId>/<uploadId>/  転送中（生成用のデータとして使わない）
  replaced/<sessionId>-<時刻>/      同じセッションを送り直したときの前の版
```

- `sessions/` には完了したものしか置きません（staging で全部確かめてから、フォルダごと rename）。
- 撮り直してから送り直すと manifestHash が変わるので、新しい版として受け取り、前の版は `replaced/` に移します。
