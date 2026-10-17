// ② ホーム（/）。タブ。
// 画面いっぱいの 3D の家（HomeScene）。はじめはリビングの中を壁の上から見下ろす近景で、引けば 4 部屋の家全体まで見える
// （カメラの側と部屋どうしの間の壁はカットする）。ドラッグで見回せて、放っておくとゆっくり回る。作品をタップすると ⑥ 作品の詳細へ。
// 3D の上に浮かぶ UI は 2 段だけ：上に館名とアバター（⑩ 設定へ）、タブバーのすぐ上に飾っている数と「歩く」（⑪ 鑑賞モード）・
// 「模様替え」（⑫）の丸いボタン。作品の追加はタブバーの「＋」から。
// スマホの枠（.app）は、ほかのタブと同じく残す（PC で枠を外すのは ⑪ と ⑫ だけ）。
import { Suspense, useEffect, useState } from 'react'
import { useMuseum } from '../api'
import { GlassButton, Screen, TLink } from '../components'
import { SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { HomeScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './Home.css'

export default function Home() {
  const museum = useMuseum()
  const nav = useNav()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  const data = museum.data
  const initial = (data?.owner_name ?? 'は').slice(0, 1)
  // しまってある（飾っていない）作品の数
  const stored = data ? data.total_artworks - data.displayed_count : 0

  return (
    <Screen tabbar className="home-screen">
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
    </Screen>
  )
}
