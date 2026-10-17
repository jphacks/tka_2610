# AGENTS.md

このリポジトリで作業する AI エージェント向けのメモです。人向けの説明は [README.md](README.md) にあります。
内容は 2026年10月時点のものです。

## 構成

| ディレクトリ | 中身 | 役割 |
|---|---|---|
| `backend/` | Rust（axum + sqlx + PostgreSQL） | 写真の処理、GLB の生成、展示台の割り当てなど、処理はすべてここ |
| `web/` | React + Vite + three.js | 表示だけ。処理を足すときは `backend/` に書く |
| `unity/` | Unity 6000.3.22f1 | `/api/exhibits` を 3 秒ごとに確認して展示を反映する。サーバーには書き込まない |
| `docs/` | 作業メモ | 構成の説明や、未対応の作業リストなど |

展示台の位置と部屋の割り当ては `backend/src/museum.rs` にあり、Unity の `unity/Assets/MemoryMuseum/Data/MuseumManifest.json` と同じ座標を使っています。片方を変えるときは、もう片方も合わせてください。

## 起動と確認

- 起動手順は README の「起動方法」を見てください。`.env` は `.env.example` をコピーして作ります。
- バックエンドのテスト: `cd backend && cargo test`
- Web のビルド確認: `cd web && npm run build`

Web の構成（画面・共通部品・3D・スタイル）と、変更するときの決まりは [docs/frontend.md](docs/frontend.md) にあります。

## 守ること

- **適用済みのマイグレーションを書き換えない。** `backend/migrations/` の既存ファイルを変えるとチェックサムが変わり、サーバーが `VersionMismatch` で起動できなくなります。変更は新しい番号のファイルで足してください。
- **SQL の改行コードを `.gitattributes` で固定しない。** Windows では CRLF のまま適用済みの環境があり、LF に固定するとその環境で起動できなくなります。詳しくは [docs/supabase.md](docs/supabase.md) の「マイグレーションの改行コード対策」を見てください。
- **写真から GLB を作る処理（`backend/src/glb.rs`）は仮の実装です。** 差し替える前提で扱ってください。
- **Web の画面から `web/src/three/scenes/` の中を直接 import しない。** 必ず `import { ... } from '../three'`（`web/src/three/index.tsx`）を使います。直接読むと three.js が最初に読み込まれ、表示が遅くなります。
- **Web の CSS は、1 か所でだけ使うものはその `.tsx` の隣の同じ名前の `.css` に、2 か所以上で使うものは `web/src/styles/` に書く。** 色は `web/src/styles/tokens.css` の CSS 変数を使い、直接書かない。
- **`.env` や接続文字列、パスワードをコミットしない。**
- **コミットメッセージや PR の説明に、AI ツールの署名（`Co-Authored-By` や「Generated with」など）を入れない。**

## 未対応・予定

- Supabase への移行: [docs/supabase.md](docs/supabase.md)
- ログイン画面（デザイン案の①）は未実装です。
