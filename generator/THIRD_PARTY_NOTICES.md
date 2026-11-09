# 使っているほかのソフトウェア

`generator/` の `kt` は、次のソフトウェアを呼び出して動きます。**どれもこのリポジトリには入っていません。** 使う人が手元に入れます（入れ方は [README.md](README.md)）。

## Katachi Loop Studio 0.5.0

`kt` はモデリングの処理を Katachi Loop Studio の Python のパッケージ（`katachi`）から呼び出します。本体は配布されている zip を手元に展開し、`setup.sh`（Windows は `setup.ps1`）が `.venv` に editable で入れます。`kt viewer install` だけが、Katachi の `web/` フォルダに工程ビューアのファイル（`katachi_web/`）を足します。

```
MIT License

Copyright (c) 2026 Katachi Loop Studio contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Hunyuan3D-2.1（任意。曲面の物の形の生成）

`kt gen` と、`kt auto` が曲面の物を生成に回すときに使います。`setup_gen.sh`（Windows は `setup_gen.ps1`）が、リポジトリの外（`~/.cache/katachi-tools/hy3d/`。環境変数 `KT_HY3D_HOME` で変えられる）にコードと重み `hunyuan3d-dit-v2-1`（7.37 GB）を落とします。

ライセンスは **Tencent Hunyuan 3D 2.1 Community License** です。EU・イギリス・韓国では使えません。生成物をほかの AI モデルの改良に使ってはいけません。詳しくは落としたフォルダの `Hunyuan3D-2.1/LICENSE` を見てください。

## そのほか

- rembg（背景の切り抜き。モデル `isnet-general-use` は最初の実行で `~/.rembg` に落ちる）・onnxruntime：`requirements.txt` で入れる
- LaMa（任意。指の下の絵を埋める。Apache-2.0）：`lama_fp32.onnx` を `~/.cache/katachi-tools/lama/` に置くか、`KT_LAMA_ONNX` で場所を指定したときだけ使う
- Claude Code（`claude` コマンド）：`kt auto` の振り分けと素材の判断で呼ぶ（`claude -p`。API キーは使わず、Claude Code のログインを使う）
