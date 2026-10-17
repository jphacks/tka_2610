// ⑦ 博物館のマップ（/map）。タブ。
// 見取り図の 3D（フロアの切り替え）と、展示室のリスト。
import { Suspense, useEffect, useState } from 'react'
import { useMuseum } from '../api'
import { ActionMenu, Img, NavBar, Screen, Segmented } from '../components'
import { ChevronRight, GalleryIcon, MoreIcon, MuseumIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { MapScene, StageShell, warmUp3D } from '../three'
import './MapView.css'

type Floor = '1F' | '2F'

export default function MapView() {
  const museum = useMuseum()
  const nav = useNav()
  const [floor, setFloor] = useState<Floor>('1F')
  const [ready, setReady] = useState(false)
  const [menu, setMenu] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(museum.data.model_url)
  }, [museum.data])

  const rooms = museum.data?.rooms ?? []

  return (
    <Screen tabbar>
      <NavBar
        large
        eyebrow="ミュージアム"
        title={museum.data?.name ?? 'はるのミュージアム'}
        right={
          <button className="icon-btn" aria-label="メニュー" onClick={() => setMenu(true)}>
            <MoreIcon size={21} />
          </button>
        }
      />

      <div className="map-controls">
        <Segmented<Floor>
          label="フロア"
          options={[
            { value: '1F', label: '1F' },
            { value: '2F', label: '2F' },
          ]}
          value={floor}
          onChange={setFloor}
        />
      </div>

      <StageShell className="map-stage" ready={ready || (!!museum.data && !museum.data.model_url)}>
        {museum.data && (
          <Suspense fallback={null}>
            <MapScene
              museum={museum.data}
              floor={floor}
              onRoom={(id) => nav.push(`/museum?room=${id}`)}
              onReady={() => setReady(true)}
            />
          </Suspense>
        )}
      </StageShell>

      <div className="page">
        <div className="section-head">
          <h2>展示室</h2>
          <button className="btn-plain" onClick={() => nav.push('/museum')}>
            館内を歩く
          </button>
        </div>
        <div className="list-group" style={{ marginTop: 0 }}>
          {rooms.map((room) => (
            <button key={room.id} className="list-item room-row" onClick={() => nav.push(`/museum?room=${room.id}`)}>
              {room.thumbs[0] ? (
                <Img src={room.thumbs[0]} tint={room.tint} alt="" />
              ) : (
                <div className="thumb">
                  <MuseumIcon size={22} />
                </div>
              )}
              <span className="grow">
                <div className="name">{room.name}</div>
                <div className="desc">
                  {room.description}・{room.floors.join('/')}
                </div>
              </span>
              <span className="detail">
                {room.count} / {room.capacity}
              </span>
              <ChevronRight size={16} strokeWidth={2.2} className="chev" />
            </button>
          ))}
        </div>
        <p className="note">作品は種類ごとの部屋に自動で飾られ、Unity の博物館にも同じ場所で表示されます。</p>
      </div>

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: '館内を歩く', icon: <WalkIcon size={19} />, onSelect: () => nav.push('/museum') },
          { label: '作品一覧', icon: <GalleryIcon size={19} />, onSelect: () => nav.tab('/collection') },
        ]}
      />
    </Screen>
  )
}
