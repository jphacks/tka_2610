// ⑦ おうちのマップ（/map）。タブ。
// 家全体（今はリビングだけ）を上から見下ろす 3D と、部屋のリスト。リストの下の「模様替え」から ⑫ 模様替えへ。
// 3D の部屋の名前のラベルを押すと、カメラがその部屋へ寄る。寄っている部屋のラベルをもう一度押すと、その部屋の ⑤ おうちの中へ。
// 寄っている間は左上の「家全体」で、家全体の見え方へ戻る。
// 「⋯」のメニューから、⑤ おうちの中・⑪ 鑑賞モード（PC とスマホのどちらでも歩ける）・⑧ 作品一覧へ進める。
import { Suspense, useEffect, useState } from 'react'
import { useMuseum } from '../api'
import { ActionMenu, Img, NavBar, Screen } from '../components'
import { ChevronRight, GalleryIcon, MoreIcon, MuseumIcon, SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { MapScene, StageShell, furnitureUrlsOf, hasHouseModel, shellUrlsOf, warmUp3D } from '../three'
import './MapView.css'

export default function MapView() {
  const museum = useMuseum()
  const nav = useNav()
  const [ready, setReady] = useState(false)
  const [menu, setMenu] = useState(false)
  /** カメラが寄っている部屋（null なら家全体） */
  const [focusRoom, setFocusRoom] = useState<string | null>(null)

  useEffect(() => {
    if (museum.data) warmUp3D(shellUrlsOf(museum.data), furnitureUrlsOf(museum.data))
  }, [museum.data])

  /** ラベルを押した：はじめは寄るだけ。寄っている部屋をもう一度押したら、その部屋の「おうちの中」へ */
  const onRoom = (id: string) => {
    if (focusRoom === id) nav.push(museum.data ? `/museum?room=${museum.data.room.id}` : '/museum')
    else setFocusRoom(id)
  }

  const rooms = museum.data?.rooms ?? []

  return (
    <Screen tabbar>
      <NavBar
        large
        eyebrow="おうち"
        title={museum.data?.name ?? 'はるのミュージアム'}
        right={
          <button className="icon-btn" aria-label="メニュー" onClick={() => setMenu(true)}>
            <MoreIcon size={21} />
          </button>
        }
      />

      <StageShell
        className="map-stage"
        ready={ready || (!!museum.data && !hasHouseModel(museum.data))}
        overlay={
          focusRoom && (
            <button type="button" className="map-whole glass" onClick={() => setFocusRoom(null)}>
              家全体
            </button>
          )
        }
      >
        {museum.data && (
          <Suspense fallback={null}>
            <MapScene museum={museum.data} focusRoom={focusRoom} onRoom={onRoom} onReady={() => setReady(true)} />
          </Suspense>
        )}
      </StageShell>

      <div className="page">
        <div className="section-head">
          <h2>お部屋</h2>
          <button className="btn-plain" onClick={() => nav.push('/museum')}>
            おうちに入る
          </button>
        </div>
        <div className="list-group" style={{ marginTop: 0 }}>
          {rooms.map((room) => (
            <button key={room.id} className="list-item room-row" onClick={() => nav.push(museum.data ? `/museum?room=${museum.data.room.id}` : '/museum')}>
              {room.thumbs[0] ? (
                <Img src={room.thumbs[0]} tint={room.tint} alt="" />
              ) : (
                <div className="thumb">
                  <MuseumIcon size={22} />
                </div>
              )}
              <span className="grow">
                <div className="name">{room.name}</div>
                <div className="desc">{room.description}</div>
              </span>
              <span className="detail">
                {room.count} / {room.capacity}
              </span>
              <ChevronRight size={16} strokeWidth={2.2} className="chev" />
            </button>
          ))}
          <button className="list-item room-row" onClick={() => nav.push('/home/edit')}>
            <div className="thumb">
              <SofaIcon size={22} />
            </div>
            <span className="grow">
              <div className="name">模様替え</div>
              <div className="desc">家具を動かしたり、作品を飾ったりする</div>
            </span>
            <ChevronRight size={16} strokeWidth={2.2} className="chev" />
          </button>
        </div>
        <p className="note">作品を飾ると、空いている棚や机の上に自動で置かれます。</p>
      </div>

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: 'おうちに入る', icon: <MuseumIcon size={19} />, onSelect: () => nav.push('/museum') },
          { label: '鑑賞モード', icon: <WalkIcon size={19} />, onSelect: () => nav.push('/museum/walk') },
          { label: '作品一覧', icon: <GalleryIcon size={19} />, onSelect: () => nav.tab('/collection') },
        ]}
      />
    </Screen>
  )
}
