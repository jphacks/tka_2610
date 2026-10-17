// ② ホーム（/）。タブ。
import { Suspense, useEffect, useState } from 'react'
import { useMuseum } from '../api'
import { GlassButton, Screen, TLink } from '../components'
import { SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { HomeScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './Home.css'

// 1. 招待状コンポーネントをインポート
import { InviteSheet } from '../components'

export default function Home() {
  const museum = useMuseum()
  const nav = useNav()
  const [ready, setReady] = useState(false)

  // 2. 招待状シートの開閉状態を追加
  const [showInvite, setShowInvite] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  const data = museum.data
  const initial = (data?.owner_name ?? 'は').slice(0, 1)
  const stored = data ? data.total_artworks - data.displayed_count : 0

  return (
    <Screen tabbar className="home-screen">
      <StageShell
        className="home-stage"
        ready={ready || (!!data && !hasHouseModel(data))}
        overlay={
          <>
            <div className="stage-top home-top">
              {/* 3. 左上を「招待状を発行」ボタンに変更 */}
              {data && (
                <button
                  type="button"
                  className="stage-title glass home-title"
                  onClick={() => {
                    setShowInvite(true);
                    
                  }}
                  style={{
                    position: 'relative',
                    zIndex: 99999,
                    pointerEvents: 'auto',
                    cursor: 'pointer',
                  }}
                  //title="招待状を発行する"
                >
                  <span>招待状を発行する</span> 
                </button>
              )}
              
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

      {/* 4. 画面の一番下に下から出る招待状シートを配置 */}
      <InviteSheet 
        Open={showInvite} 
        onClose={() => setShowInvite(false)} 
      />
    </Screen>
  )
}