// 画面の一覧（URL → pages/ の画面）と、全画面で共通の部品（下部タブ・お知らせ・遷移の通知）。
// 画面を足すときは、pages/ にファイルを作り、ここに Route を 1 行足す。
// コメントの番号はデザイン案の番号、「タブ」「モーダル」などは画面遷移の種類（nav.ts）。
//
// 画面そのものは小さいので最初にまとめて読み込み、遷移アニメーション中に
// 白い画面が挟まらないようにする。重い 3D（three.js）だけは遅延読み込み（three/index.tsx）。

import { QueryClientProvider } from '@tanstack/react-query'
import { BrowserRouter, Route, Routes } from 'react-router-dom'
import { queryClient } from './api'
import { TabBar, ToastProvider } from './components'
import { RouteRendered } from './nav'
import AddArtwork from './pages/AddArtwork'
import ArtworkDetail from './pages/ArtworkDetail'
import ArtworkPreview from './pages/ArtworkPreview'
import Collection from './pages/Collection'
import EditArtwork from './pages/EditArtwork'
import Home from './pages/Home'
import HomeEdit from './pages/HomeEdit'
import MapView from './pages/MapView'
import MuseumView from './pages/MuseumView'
import MuseumWalk from './pages/MuseumWalk'
import Room from './pages/Room'
import Settings from './pages/Settings'
import './App.css'

export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <div className="app">
          <ToastProvider>
            <Routes>
              {/* ② ホーム（タブ） */}
              <Route path="/" element={<Home />} />
              {/* ⑧ 作品一覧（タブ）。?category=種類 で絞り込む */}
              <Route path="/collection" element={<Collection />} />
              {/* ⑦ 博物館のマップ（タブ） */}
              <Route path="/map" element={<MapView />} />
              {/* ⑩ 設定（タブ） */}
              <Route path="/settings" element={<Settings />} />
              {/* ③ 作品を追加（モーダル） */}
              <Route path="/add" element={<AddArtwork />} />
              {/* ⑥ 作品の詳細（push） */}
              <Route path="/artworks/:id" element={<ArtworkDetail />} />
              {/* ⑨ 作品を編集（モーダル） */}
              <Route path="/artworks/:id/edit" element={<EditArtwork />} />
              {/* ④ 3D プレビュー（モーダル） */}
              <Route path="/artworks/:id/preview" element={<ArtworkPreview />} />
              {/* おへや（push）。年齢ごとの部屋の 3D。ホームの積み上げの建物から開く */}
              <Route path="/rooms/:roomId" element={<Room />} />
              {/* ⑤ おうちの中（push）。?room=おへやの id、?focus=作品ID でカメラを寄せる */}
              <Route path="/museum" element={<MuseumView />} />
              {/* ⑪ 鑑賞モード（push。?room=おへやの id）。おへやの中を一人称で歩く。PC は WASD とマウス、スマホはタッチ（仮想スティックとなぞる操作） */}
              <Route path="/museum/walk" element={<MuseumWalk />} />
              {/* ⑫ 模様替え（push。?room=おへやの id）。家具や作品をドラッグで動かす・回す・消す・足す。HomeEdit */}
              <Route path="/home/edit" element={<HomeEdit />} />
              {/* どれにも当てはまらない URL はホームを出す */}
              <Route path="*" element={<Home />} />
            </Routes>
            {/* 下部タブ。タブの画面（components/TabBar.tsx の TABS）でだけ表示される */}
            <TabBar />
            {/* 新しい画面の描画が終わったことを、遷移アニメーションに知らせる */}
            <RouteRendered />
          </ToastProvider>
        </div>
      </BrowserRouter>
    </QueryClientProvider>
  )
}
