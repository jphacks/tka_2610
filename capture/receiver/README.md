# 受信サーバー（Mac 側）

iPhone の Memoria Capture から、同じ Wi-Fi で撮影セッションを受け取ります。コマンドは `capture/` のフォルダで実行します。Python 3.9 以上の標準ライブラリだけで動きます（pip は不要）。外部のクラウドには何も送りません。

## 起動

```sh
python3 receiver/memoria_receiver.py            # serve と同じ。ポート 8765、保存先は capture/captures/
python3 receiver/memoria_receiver.py serve --port 8765 --data-dir ~/memoria-captures
```

| オプション | 意味 |
|---|---|
| `--port` | 待ち受けるポート（既定 8765） |
| `--host` | 待ち受けるアドレス（既定 `0.0.0.0`） |
| `--data-dir` | 保存先（既定は `capture/captures/`。アプリのサーバーもここを読む（`CAPTURE_DATA_DIR`）） |
| `--no-bonjour` | Bonjour で広告しない |
| `--reset-code` | ペアリングコードを作り直す |
| `--fail-put-every N` | **テスト専用。** N 回に 1 回 PUT を 500 で失敗させ、iPhone の再送を確かめる（環境変数 `MEMORIA_FAIL_PUT_EVERY` でも可）。ふだんは使わない |

ポート 8765 は、`generator/` の Katachi の画面（`http://127.0.0.1:8765`）と同じです。Katachi を同じ Mac で動かしているときは `--port 8766` のように別の番号にしてください。

起動すると、ペアリングコード（6 桁）、`http://<IP>:<port>` の URL、保存先、Bonjour の状態を表示します。止めるときは Ctrl-C。

初めて起動したとき、macOS が「python3 への受信接続を許可しますか」と聞くことがあります。**許可してください**（拒否すると iPhone からつながりません。あとから システム設定 → ネットワーク → ファイアウォール で変えられます）。

## iPhone からつなぐ

1. Mac と iPhone を同じ Wi-Fi につなぎ、受信サーバーを起動する。
2. iPhone のアプリの送信先の一覧に Mac の名前が出る（Bonjour `_memoriacap._tcp`）。出ないときは、起動時に表示された `http://<IP>:<port>` を手で入れる。
3. 起動時に表示されたペアリングコードを入れる。コードは `captures/.receiver.json` に保存され、次の起動でも同じです。

通信の決まりは [docs/transfer-protocol.md](../docs/transfer-protocol.md) にあります。

## 受け取ったデータ

- 完成したセッションは `captures/sessions/<sessionId>/` だけです。`incoming/` は転送の途中なので使いません。
- フォルダの読み方は、受信サーバーが書く `captures/README.md` にあります。形は [docs/data-format.md](../docs/data-format.md)。
- 一覧と中身の確認:

```sh
python3 receiver/memoria_receiver.py list
python3 receiver/memoria_receiver.py show <sessionId の先頭>
```

## テスト

```sh
cd receiver && python3 -m unittest -v
# capture/ からなら
python3 -m unittest discover -s receiver/tests -v
# tka_2610 の一番上からなら
python3 -m unittest discover -s capture/receiver/tests -v
```

サーバーを同じプロセスで空いているポートに立て、一時フォルダに受け取ります（Bonjour は使いません）。`sips` が無い環境では、回転したプレビューのテストだけ飛ばします。
