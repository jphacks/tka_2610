# Memoria Capture

子どもの絵や工作を 3D モデルにするための **入力の写真** をそろえる、iPhone の撮影アプリと Mac の受信側のツールです。

> このフォルダは tka_2610（GitHub の `jphacks/tka_2610`）の `capture/` です。以前は別のリポジトリで作っていましたが、今は tka_2610 が正です。ここに書いたコマンドは `capture/` から実行します（tka_2610 の一番上からなら、先に `cd capture`）。

iPhone のアプリ（表示名「Memoria」）は、**memoria（tka_2610 の Web）をアプリの中で開き、撮影だけをネイティブの画面にします**。memoria の作品追加の画面に「3D 生成で追加」が出て、立体・平面（と紙の大きさ・高さ）を選ぶと撮影画面が開き、「これで登録」で撮った写真がいつもの作品追加のフォームに入ります（下の「memoria とのつながり」）。

撮影データ一式は iPhone に残り、開発用の画面から、写真・作品のマスク（案内つきの撮り方のとき）・カメラの情報（姿勢と内部パラメータ）を同じネットワークの Mac へ送れます。Mac では、Claude Code・Codex などの AI エージェントがそのまま読める形（向きをそろえて切り出した写真・一覧の画像・おおよその大きさ・説明）にまとめます。3D の生成そのものは、このデータを読んだ AI エージェントが行います（このフォルダの範囲の外）。

撮影データ（セッション）を作るときに、作品の種類を選びます。

- **立体（工作・粘土など）**：標準は **自由に撮る**（`guidance: "free"`）。案内も自動撮影もなく、シャッターを押すだけで何枚でも撮れます（1 枚以上で送れる）。画面には「正面・横・後ろ・真上があると作りやすい」という目安だけを出し、どの写真がどの向きかは Mac で AI が写真を見て決めます。高さが分かれば、新しく撮るときに cm で入力でき（省略できる）、AI にはその高さを使うよう伝えます。案内つきの撮り方（作品を十字に合わせて iPhone の向きで正面・右・後ろ・左・真上の 5 枚を撮る「向きで案内」、先に底の中心と円柱を合わせる前の方法）は、設定で選べます。
- **平面（絵・貼り絵など）**：真上から **1 枚**（`flat1`）。新しく撮るときに紙の大きさ（八つ切・四つ切・A4・B4・A3・B5、縦と横を入力する「その他」、または「わからない」）を選びます。紙の四隅を見つけて遠近を直し、選んだ紙があればその大きさを使います（机の平面で測れたときの実寸は補助として記録します）。AI 側では 3D の形を作らず、絵を板や額に貼る形で使えます。

どちらにするかは撮る人が決めます（アプリは自動で見分けません）。

## 3 つの部分

| 部分 | 場所 | 中身 |
|---|---|---|
| 撮影アプリ | `ios/` | SwiftUI・ARKit・Vision・WebKit の iPhone アプリ（iOS 17 以上）。memoria の Web を開き、頼まれたときに撮影画面を出す。撮る方向と画質の案内、高解像度の写真とカメラの情報の保存、作品マスクの作成、Mac への送信（開発用の画面）。共通のロジックは SwiftPM のパッケージ `ios/Packages/CaptureCore` |
| 受信サーバー | `receiver/` | Python の標準ライブラリだけで動く Mac の受信サーバー。同じネットワーク（自宅の LAN・USB ケーブル・インターネット共有）からの接続だけを受け、`captures/sessions/` に保存する |
| AI 向けの入力を作るツール | `tools/claude-pack/` | `memoria-pack`。受け取ったセッションから `captures/for_claude/<sessionId>/`（入口は `brief.md`）を作る。受信サーバーが受け取るたびに自動で動かす |

ほかに、写真測量で 3D にしてみる実験用のツール `tools/reconstruct/` があります。また、平らな作品（貼り絵・紙に描いた絵）を写真 1 枚から GLB にするツール `tools/flat-art-glb/` があります（撮影アプリの流れとは別に、単独で動きます）。 上が平らな単純な立体（箱・板・操作盤など）を数枚の写真から GLB にするツール `tools/solid-glb/` もあります。

## memoria とのつながり

```
アプリを開く ─▶ memoria（WKWebView。既定は https://memoria-try.tka-2610.workers.dev）
   「＋」→ 作品を追加 →「3D 生成で追加」→ 立体 / 平面（紙・高さ）
        └─ startCapture ─▶ ネイティブの撮影画面（全画面。左上「やめる」・「これで登録」）
   作品追加のフォーム ◀─ 代表の写真（JPEG）と種類（平面 → drawing、立体 → craft）
   登録 ─▶ artworkCreated ─▶ 撮影データの local.json に memoria の作品の id（Mac へは送らない）
```

- 3D の生成は、まだつないでいません。それまでは、撮った代表の写真（平面はまっすぐに直した絵、立体は最初の写真）をいつもの作品追加のフォームに渡し、memoria の今の処理ですぐ飾ります。撮影データ一式は iPhone に残ります。
- 「3D 生成で追加」は、アプリの中（`window.MemoriaNative` があるとき）だけに出ます。Safari や PC のブラウザでは何も変わりません。
- やりとりの決まり（知らせ・返事・失敗の文言）は [docs/web-bridge.md](docs/web-bridge.md) です。
- アプリの中の memoria は、Safari とは別の家になります（Cookie が別）。今の家を使うときは、開発用の画面の「設定 > memoria」で、Safari の memoria の「この家のリンク」（`/house`）を貼ります。
- **開発用の画面**：memoria の設定の「撮影データ（開発用）」（Web が `openSessions` を送る）か、読み込めないときの画面から開きます。今までの撮影データの一覧・確認・Mac へ送る・設定（家を引き継ぐ・読み込み直す・送り先の Mac・撮り方）があり、左上の「閉じる」で memoria に戻ります。

### 手元の memoria につなぐ

ふだんは公開の memoria（`https://memoria-try.tka-2610.workers.dev`）を開きます。Mac で動かしている memoria につなぐときは：

1. tka_2610 で `web` をビルドし、`backend` を `cargo run` で起動します（:8080。家は 1 つ。手順は tka_2610 の README）。Cloudflare の開発サーバーは家の Cookie が `Secure` なので、http のままのアプリからは使えません。
2. `ios/Config/Local.xcconfig`（git に入らない。無ければ `Local.xcconfig.example` をコピー）に、次の 2 行を足します。ホストは Mac の Bonjour の名前（「システム設定 > 一般 > 共有」の「ローカルホスト名」）にし、IP アドレスは書きません。xcconfig では `//` がコメントになるので、`http://` は書かず、scheme とホストを分けます。

   ```
   MEMORIA_WEB_SCHEME = http
   MEMORIA_WEB_HOST = <Mac の名前>.local:8080
   ```

3. アプリをビルドし直して入れます（下の「はじめかた」）。http で開けるのは、Info.plist の `NSAllowsLocalNetworking`（ローカルネットワークだけ）のおかげです。公開の memoria に戻すときは、2 行を消してビルドし直します。

## はじめかた

```sh
# Mac：AI 向けの入力を作るツールをビルドしてから、受信サーバーを起動する
(cd tools/claude-pack && swift build -c release)
python3 receiver/memoria_receiver.py
```

起動すると、ペアリングコードと接続先の URL が出ます。iPhone のアプリの開発用の画面の「設定」で送り先とペアリングコードを入れ、撮影して送ると、`captures/sessions/<sessionId>/` と `captures/for_claude/<sessionId>/` ができます。iPhone へのアプリの入れ方は [AGENTS.md](AGENTS.md) の「起動と確認」にあります。

- 受信サーバーの使い方：[receiver/README.md](receiver/README.md)
- 撮影データの形（session.json・座標・画像の向き・撮影方向）：[docs/data-format.md](docs/data-format.md)
- iPhone → Mac の転送の手順：[docs/transfer-protocol.md](docs/transfer-protocol.md)
- memoria の Web とアプリの橋渡し：[docs/web-bridge.md](docs/web-bridge.md)
- AI 向けの入力の中身：[tools/claude-pack/README.md](tools/claude-pack/README.md)
- 写真測量のツール：[tools/reconstruct/README.md](tools/reconstruct/README.md)
- 平らな作品を GLB にするツール：[tools/flat-art-glb/README.md](tools/flat-art-glb/README.md)
- 上が平らな単純な立体を GLB にするツール：[tools/solid-glb/README.md](tools/solid-glb/README.md)

## 注意

- 転送は暗号化しない HTTP なので、同じネットワークの中だけで使います。受信サーバーも iPhone も、公開 IP アドレスとはやりとりしません。
- 受信サーバーとツールは、写真を外部のクラウドに送りません。画像を AI や生成サービスに渡すかどうかは、使う人が決めます。
- `captures/` は git に入りません。

AI エージェントで作業するときの決まりと、これまでに決めたこと・分かったことは [AGENTS.md](AGENTS.md) にあります。
