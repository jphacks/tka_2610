// おへや（/rooms/:roomId）。ホームで年齢を選び、積み上げの建物の階を押すと push で開く。
// 画面いっぱいの 3D のおへや（HomeScene）。はじめはおへやの中を壁の上から見下ろす近景で、ドラッグで見回せて、放っておくとゆっくり回る。
// 作品をタップすると ⑥ 作品の詳細へ。
// 3D の上に浮かぶ UI は 2 段だけ：上に戻るボタンとおへやの名前、下に飾っている数と「歩く」（⑪ 鑑賞モード）・「模様替え」（⑫）の丸いボタン。
// どちらもこのおへやを ?room= で渡す。
import { Suspense, useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useMuseum } from '../api'
import { GlassButton, Screen } from '../components'
import { BackIcon, SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { HomeScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './Room.css'

export default function Room() {
  const { roomId = '' } = useParams()
  const museum = useMuseum({ roomId })
  const nav = useNav()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  const data = museum.data
  const room = data?.room
  const back = room ? `/?age=${room.age}` : '/'

  return (
    <Screen className="room-screen">
      <StageShell
        className="room-stage"
        ready={ready || (!!data && !hasHouseModel(data)) || museum.isError}
        overlay={
          <>
            <div className="stage-top room-top">
              <GlassButton label="戻る" onClick={() => nav.back(back)}>
                <BackIcon size={20} strokeWidth={2.2} />
              </GlassButton>
              {room && <span className="stage-title glass room-title">{room.name}</span>}
            </div>
            <div className="room-dock">
              {data && (
                <p className="room-status glass">
                  <span className="num">{data.displayed_count}</span>点を飾っています
                </p>
              )}
              <div className="room-actions">
                <GlassButton label="歩く" className="room-action" onClick={() => nav.push(`/museum/walk?room=${roomId}`)}>
                  <WalkIcon size={21} />
                </GlassButton>
                <GlassButton label="模様替え" className="room-action" onClick={() => nav.push(`/home/edit?room=${roomId}`)}>
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
        {museum.isError && <div className="stage-fallback">このおへやは見つかりません</div>}
      </StageShell>
    </Screen>
  )
}
