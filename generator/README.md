# generator（写真から 3D を作る `kt`）

このアプリの **生成側** です。アプリ（入力側）で作品の写真を撮って登録したあと、作品の詳細の「写真から 3D を作る（試験中）」から、この `kt auto` を呼び出して作品の 3D モデル（GLB）を作り直します。つなぎ方は [docs/generator.md](../docs/generator.md) を見てください。

`kt` は、Katachi Loop Studio 0.5.0 のモデリング処理をサーバーを通さずに直接呼び出す道具です（もとは別のリポジトリ `kobadaidesu/3d_generator` で作り、ここへ取り込んだ）。Katachi 本体の処理には手を加えていません。

**Katachi 本体・形の生成の重み・試した写真は、このリポジトリに入っていません。** 使う人が手元に入れます（下の「準備」）。ライセンスは [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にあります。本番（Render）の入れ物にもこのフォルダは入りません。

## 準備（初回だけ）

Katachi Loop Studio 0.5.0 の zip（`KatachiLoopStudio_0.5.0_Python.zip`、約 430 MB）を展開しておきます。zip の最上位は `KatachiLoopStudio/` です。

```bash
mkdir -p ~/Downloads/KatachiLoopStudio_0.5.0_Python
unzip ~/Downloads/KatachiLoopStudio_0.5.0_Python.zip -d ~/Downloads/KatachiLoopStudio_0.5.0_Python

cd generator
./setup.sh                                    # Katachi が ~/Downloads/KatachiLoopStudio_0.5.0_Python/KatachiLoopStudio にある場合
./setup.sh /path/to/KatachiLoopStudio         # 別の場所。Python は PYTHON=python3.12 ./setup.sh のように選べる（3.11〜3.14）
./kt.sh --help
PYTHON=python3.12 ./setup_gen.sh              # 任意：曲面の物の形の生成（Python 3.10〜3.12。macOS は brew install python@3.12）
```

Windows は PowerShell で `.\setup.ps1 [-KatachiPath <フォルダ>]`・`.\setup_gen.ps1`・`.\kt.ps1` を使います（以下の `./kt.sh` は `.\kt.ps1` に読み替える）。

`setup.sh` がすること：

- 道具専用の venv（`generator/.venv`）を作る
- Katachi を editable で入れる
- `requirements.txt` の追加のパッケージ（rembg・onnxruntime・pytest）を入れる

初めて切り抜きをするときに、背景を切り抜くモデル（rembg `isnet-general-use`、約 179 MB）が `~/.rembg` に落ちます。それ以降はオフラインでも動きます。

`setup_gen.sh` は、曲面の物の形を作る AI（Hunyuan3D-2.1。形だけ）を、リポジトリの外の `~/.cache/katachi-tools/hy3d/`（環境変数 `KT_HY3D_HOME` で変えられる）に入れます。ダウンロードは合計 11〜12 GB です。NVIDIA の GPU（メモリ約 10 GB）か、Mac の GPU（MPS）を使います。`KT_HY3D_DEVICE=cpu` で CPU でも動きますが、遅いです。ライセンス（Tencent Hunyuan 3D 2.1 Community License。EU・イギリス・韓国では使えず、生成物をほかの AI モデルの改良に使えない）に注意してください。

任意：指の下の絵を埋める AI（LaMa、約 208 MB、Apache-2.0）。[Carve/LaMa-ONNX](https://huggingface.co/Carve/LaMa-ONNX) の `lama_fp32.onnx` を `~/.cache/katachi-tools/lama/lama_fp32.onnx` に置く（または `KT_LAMA_ONNX` で場所を指定する）と使います。無くても動きます（紙の地で埋める）。

`kt auto` の振り分けと、`kt gen` の素材の判断には Claude Code（`claude` コマンド）が要ります（`claude -p` で呼ぶ。API キーは使わず、Claude Code のログインを使う）。

## どんな物でも 1 コマンドで（`kt auto`）

アプリから呼ぶのはこれです。

```bash
./kt.sh auto 写真1.jpg 写真2.jpg 写真3.jpg --size 16,10.6,6.6 --out 出力フォルダ [--ai-model sonnet]
```

- 写真はファイル（`.jpg`・`.jpeg`・`.png`・`.webp`）か、写真のフォルダを渡します。
- `--size` は分かっている寸法（cm、1〜3 個、順不同）です。
- 出力フォルダに `model.glb`（できたモデル）・`report.json`・`compare.jpg` などができます。失敗すると 0 以外で終わります。

1. **計測**：プログラムが写真ごとに測ります（四角形の辺の裏付けとはみ出し、切り抜きの面積・細長さ・凹凸・四角さ）。
2. **振り分け**：AI を 1 回呼び、写真と計測値から作り方を選ばせます。箱（box、`--look ai`）、平面（flat）、ボトル（bottle）、回転体（revolve）、それ以外（generate）のどれかです。写真と寸法の割り当ても AI が決めます。判断が不完全なら、理由を表示して止まります（勝手に別の方法へは回さない）。
3. **実行**：選んだ方法で作ります。出力フォルダには `route_decision.json`（判断・計測値・時間）と、その方法の出力が出ます。

かかる時間は、箱・ボトル・平面で 1 分前後、形の生成（generate）で 3 分前後です（GPU による）。

## 曲面の物（`kt gen`）

```bash
./kt.sh gen --photo main=上から.jpg@0,70 --photo back=裏から.jpg@180,-70 --size 16,6.6,10.6
```

1. **形の生成**：1 枚目の写真を切り抜き、Hunyuan3D-2.1 で形を作ります。手元の GPU で動きます。
2. **向きと大きさ**：生成した形を、90° 回転 24 通りのうち外接箱の比率が `--size` にいちばん近い向きにして、軸ごとに `--size` へ縮めます。
3. **素材**（`--material regions`、既定）：写真の色を形へ写して領域に分け、AI 1 回で領域ごとの素材（色・つや・金属感）と残す印（記号・文字）を決めます。`--material one` は全体を 1 色にします。
4. **出力**：`model.glb`・`compare.jpg`・`views.jpg`・`render_hero.png`・`gen/input.png`・`paint/`。生成の設定は `--steps`・`--octree`・`--seed`・`--max-faces` で変えられます。

## テンプレートを直接使う

```bash
./kt.sh sheet   <写真フォルダ>        # 全部の写真を 1 枚の一覧画像にまとめる
./kt.sh box     --front 表.jpg [表2.jpg ...] --back 裏.jpg --side 背.jpg --size 183x233[x22] [--kind book|box] [--side2 右.jpg --top 上.jpg]
./kt.sh bottle  --front 正面.jpg --side 側面.jpg [--back 背面.jpg --side2 反対側.jpg] --height-cm 20 [--cap auto|none|plain|ribbed] [--print photo|none]
./kt.sh flat    --photo 作品.jpg [作品2.jpg ...] --width-cm 20 [--height-cm 15] [--thickness-mm 1.5] [--mode auto|rect|cutout]
./kt.sh revolve --photo 横から.jpg --height-cm 15 [--hollow --wall-mm 3]
```

共通のオプション：`--title`、`--out`（既定は写真フォルダの中の `3d_<種類>`）、`--ui`（起動中の Katachi の画面にも登録する）、`--render-size`、`--fit N`。

| テンプレート | 対象 | 仕組み |
|---|---|---|
| box | 本・箱・カード | 直線から四隅を検出して遠近を補正し、写真の模様を面に貼る。影をならし（`--lighting keep` で無効）、光沢を写真のテカりから判定する（`--finish auto\|matte\|glossy`） |
| bottle | 容器・ボトル | 正面の幅・側面の厚みから断面 22 個の loft を作る。キャップは色の帯から検出する |
| flat | 絵・カード・紙工作 | 紙の四角形（rect）か切り抜いた輪郭（cutout）で板を作り、表面に写真を貼る |
| revolve | コップ・花瓶・皿 | 横からの写真 1 枚から半径の変化を求めて回転体を作る |

同じ面の写真を 2 枚以上渡すと、1 枚目を使い、指やテカりで隠れた所を 2 枚目以降から補います。

そのほか、AI が Katachi のレシピを書くための道具（`kt inspect face|edge|views`・`kt recipe`）と、Katachi の画面に工程ビューアを足す `kt viewer install|status|uninstall` があります（`./kt.sh --help`）。Katachi の画面は `http://127.0.0.1:8765` で、iPhone の撮影アプリの受信サーバー（`capture/receiver`）の既定のポートと同じです。両方を動かすときは、受信サーバーを `--port 8766` のように別の番号で起動してください。

## 撮影のコツ

1. 手で持たず、無地の背景に置いて撮る。手で持つしかないときは、持つ位置を変えてもう 1 枚撮って両方渡す。
2. 物を写真の中に全部入れる（はみ出すと推定になる）。
3. 正面・側面はできるだけ真正面から撮る。
4. 光沢のある面は照明の映り込みを避け、スマホの影がかからないようにする。
5. 実際の寸法を測って渡す。

## テスト

```bash
cd generator
.venv/bin/python -m pytest -q
```

Katachi を入れた `.venv` が要ります（CI では流していません）。実写の写真を使うテストは、写真（`~/Pictures/作品`、または `KT_WORKS_DIR`）が無ければ飛ばします。試した写真はこのリポジトリに入れていません。

## 限界

- しわ・浮き出し・曲面に描かれた模様は形にしない。
- 写真 1 枚では、平面の縦横比や見えない面は決まらない。推定した所は `scene.json` の `assumptions` と `report.json` に書く。
- 手で持った写真は輪郭が隠れる。指の除去は肌色が手がかりなので、肌に近い色の面では面の上の指を消さない。
- 振り分けと素材は AI の判断なので、実行のたびに少し変わることがある。
- 品質の目安（輪郭の IoU など）は `report.json` に書くが、2D の一致度で、3D の正確さではない。採用するかは `compare.jpg` を見て決める。
