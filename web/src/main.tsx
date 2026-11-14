// アプリの起動。全体のスタイルを読み込み、App（画面の一覧）を描画するだけ（と、マウスで列を動かす dragScroll の準備）。
// 画面の一覧は App.tsx にある。

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// 全体のスタイルは、部品や画面の .css より先に読み込む（後から読んだ方が優先される）
import './styles/index.css'
import App from './App'
import { installDragScroll } from './dragScroll'

// 横に流れる列（data-drag-scroll）を、PC のマウスでつかんで動かせるようにする
installDragScroll()

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
