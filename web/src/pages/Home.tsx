// ② ホーム（/）。タブ。
// 画面いっぱいの 3D の家（HomeScene）。はじめはリビングの中を壁の上から見下ろす近景で、引けば 4 部屋の家全体まで見える
// （カメラの側と部屋どうしの間の壁はカットする）。ドラッグで見回せて、放っておくとゆっくり回る。作品をタップすると ⑥ 作品の詳細へ。
// 3D の上に浮かぶ UI は 2 段だけ：上に館名とアバター（⑩ 設定へ）、タブバーのすぐ上に飾っている数と「歩く」（⑪ 鑑賞モード）・
// 「模様替え」（⑫）の丸いボタン。作品の追加はタブバーの「＋」から。
// スマホの枠（.app）は、ほかのタブと同じく残す（PC で枠を外すのは ⑪ と ⑫ だけ）。
// ② ホーム（/）。タブ。
import { Suspense, useEffect, useState } from 'react'
import { useMuseum } from '../api'
import { GlassButton, Screen, TLink } from '../components'
import { SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { HomeScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './Home.css'

// 1. 招待状のコンポーネントをインポート
import { InviteSheet } from '../components'

export default function Home() {
  const museum = useMuseum()
  const nav = useNav()
  const [ready, setReady] = useState(false)

  // 2. 招待状シートを開くかどうかの状態を追加
  const [showInvite, setShowInvite] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  const data = museum.data
  const initial = (data?.owner_name ?? 'は').slice(0, 1)
  const stored = data ? data.total_artworks - data.displayed_count : 0

  return (
    <Screen tabbar className="home-screen">
      {/* テスト用：画面の右上に出す「招待状を開く」ボタン */}
      <div style={{ position: 'fixed', top: 10, right: 10, zIndex: 1000 }}>
        <button 
          onClick={() => setShowInvite(true)}
          style={{ background: '#fff', padding: '6px 12px', borderRadius: '8px', border: '1px solid #ccc', cursor: 'pointer', boxShadow: '0 2px 8px rgba(0,0,0,0.15)' }}
        >
          💌 招待状を見る
        </button>
      </div>

      <StageShell
        className="home-stage"
        ready={ready || (!!data && !hasHouseModel(data))}
        overlay={
          <>
            <div className="stage-top home-top">
              {data && <span className="stage-title glass home-title">{data.name}</span>}
              <TLink to="/settings" kind="tab" className="avatar home-avatar" aria-label="マイページ">
                {initial}
              </TLink>
            </div>
            <div className="home-dock">
              {data && (
                <p className="home-status glass">
                  <span className="num">{data.displayed_count}</span>点を飾っています
                  {stored > 0 && (
                    <>
                      ・しまってある <span className="num">{stored}</span>
                    </>
                  )}
                </p>
              )}
              <div className="home-actions">
                <GlassButton label="歩く" className="home-action" onClick={() => nav.push('/museum/walk')}>
                  <WalkIcon size={21} />
                </GlassButton>
                <GlassButton label="模様替え" className="home-action" onClick={() => nav.push('/home/edit')}>
                  <SofaIcon size={21} />
                </GlassButton>
              </div>
            </div>
          </>
        }
      >
        {data && (
          <Suspense fallback={null}>
            <HomeScene museum={data} onSelect={(id) => nav.push(`/artworks/${id}`)} onReady={() => setReady(true)} />
          </Suspense>
        )}
        {data && !hasHouseModel(data) && <div className="stage-fallback">家の 3D モデル (GLB) が見つかりません</div>}
      </StageShell>

      {/* 3. 招待状のシート（InviteSheet）を配置 */}
      <InviteSheet 
        Open={showInvite} 
        onClose={() => setShowInvite(false)} 
      />
    </Screen>
  )
}