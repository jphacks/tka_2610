// ⑤ おうちの中（/museum）。push で開く。
// 手前の壁をカットした家をドラッグでぐるりと見回し（どの向きからでも）、作品をタップすると詳細へ。?focus=作品ID / ?room=部屋ID でカメラを寄せる。
// 「⋯」のメニューから、⑪ 鑑賞モード（家の中を一人称で歩く。PC はキーボードとマウス、スマホはタッチ）と ⑫ 模様替えへ進める。
import { Suspense, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useMuseum } from '../api'
import { ActionMenu, GlassButton, Screen } from '../components'
import { BackIcon, GalleryIcon, HomeIcon, MoreIcon, MuseumIcon, PlusIcon, SofaIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import { MuseumScene, StageShell, hasHouseModel } from '../three'
import './MuseumView.css'

export default function MuseumView() {
  const museum = useMuseum()
  const nav = useNav()
  const [params] = useSearchParams()
  const [ready, setReady] = useState(false)
  const [menu, setMenu] = useState(false)
  const focus = params.get('focus')
  const room = params.get('room')

  const focusedTitle = focus ? museum.data?.slots.find((s) => s.artwork?.id === focus)?.artwork?.title : null
  const roomName = room ? museum.data?.rooms.find((r) => r.id === room)?.name : null

  return (
    <Screen>
      <StageShell
        className="fullscreen-stage"
        ready={ready || (!!museum.data && !hasHouseModel(museum.data))}
        overlay={
          <>
            <div className="stage-top">
              <GlassButton label="戻る" onClick={() => nav.back('/')}>
                <BackIcon size={20} strokeWidth={2.2} />
              </GlassButton>
              <span className="stage-title glass">{museum.data?.name ?? 'はるのミュージアム'}</span>
              <GlassButton label="メニュー" onClick={() => setMenu(true)}>
                <MoreIcon size={20} />
              </GlassButton>
            </div>
            <div className="museum-bottom">
              <div className="museum-caption">
                <p>
                  {focusedTitle
                    ? `「${focusedTitle}」を飾りました`
                    : roomName ?? '子どもの頃の作品たちが、今もここに。'}
                </p>
                {ready && <small>ドラッグで見回す ・ 作品をタップで詳しく</small>}
              </div>
              <div className="toolbar">
                <button className="glass-pill glass" onClick={() => nav.push('/map')}>
                  <MuseumIcon size={18} />
                  マップ
                </button>
                <button className="glass-pill glass" onClick={() => nav.modal('/add')}>
                  <PlusIcon size={17} strokeWidth={2.2} />
                  作品を追加
                </button>
              </div>
            </div>
          </>
        }
      >
        {museum.data && (
          <Suspense fallback={null}>
            <MuseumScene
              museum={museum.data}
              focusId={focus}
              roomId={room}
              onSelect={(id) => nav.push(`/artworks/${id}`)}
              onReady={() => setReady(true)}
            />
          </Suspense>
        )}
        {museum.data && !hasHouseModel(museum.data) && (
          <div className="stage-fallback">家の 3D モデル (GLB) が見つかりません</div>
        )}
      </StageShell>

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: '鑑賞モード', icon: <WalkIcon size={19} />, onSelect: () => nav.push('/museum/walk') },
          { label: '模様替え', icon: <SofaIcon size={19} />, onSelect: () => nav.push('/home/edit') },
          { label: 'マップ', icon: <MuseumIcon size={19} />, onSelect: () => nav.push('/map') },
          { label: '作品一覧', icon: <GalleryIcon size={19} />, onSelect: () => nav.tab('/collection') },
          { label: 'ホーム', icon: <HomeIcon size={19} />, onSelect: () => nav.tab('/') },
        ]}
      />
    </Screen>
  )
}
