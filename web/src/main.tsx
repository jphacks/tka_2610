// アプリの起動。全体のスタイルを読み込み、App（画面の一覧）を描画するだけ。
// 画面の一覧は App.tsx にある。

import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
// 全体のスタイルは、部品や画面の .css より先に読み込む（後から読んだ方が優先される）
import './styles/index.css'
import App from './App'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
