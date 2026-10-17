// ⑤ おうちの中（/museum?room=おへやの id）。push で開く。おへや（年齢ごとの部屋）は ?room= で選ぶ（省くと今の年齢のおへや）。
// 手前の壁をカットした家をドラッグでぐるりと見回し（どの向きからでも）、作品をタップすると詳細へ。?focus=作品ID でカメラを寄せる。
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
  const [params] = useSearchParams()
  const museum = useMuseum({ roomId: params.get('room') })
  const nav = useNav()
  const [ready, setReady] = useState(false)
  const [menu, setMenu] = useState(false)
  const focus = params.get('focus')
  const ageRoom = museum.data?.room ?? null
  const inRoom = (path: string) => (ageRoom ? `${path}?room=${ageRoom.id}` : path)

  const focusedTitle = focus ? museum.data?.slots.find((s) => s.artwork?.id === focus)?.artwork?.title : null

  return (
    <Screen>
      <StageShell
        className="fullscreen-stage"
        ready={ready || (!!museum.data && !hasHouseModel(museum.data))}
        overlay={
          <>
            <div className="stage-top">
              <GlassButton label="戻る" onClick={() => nav.back(ageRoom ? `/rooms/${ageRoom.id}` : '/')}>
                <BackIcon size={20} strokeWidth={2.2} />
              </GlassButton>
              <span className="stage-title glass">{ageRoom?.name ?? museum.data?.name ?? 'おへや'}</span>
              <GlassButton label="メニュー" onClick={() => setMenu(true)}>
                <MoreIcon size={20} />
              </GlassButton>
            </div>
            <div className="museum-bottom">
              <div className="museum-caption">
                <p>
                  {focusedTitle
                    ? `「${focusedTitle}」を飾りました`
                    : '子どもの頃の作品たちが、今もここに。'}
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
          { label: '鑑賞モード', icon: <WalkIcon size={19} />, onSelect: () => nav.push(inRoom('/museum/walk')) },
          { label: '模様替え', icon: <SofaIcon size={19} />, onSelect: () => nav.push(inRoom('/home/edit')) },
          { label: 'マップ', icon: <MuseumIcon size={19} />, onSelect: () => nav.push('/map') },
          { label: '作品一覧', icon: <GalleryIcon size={19} />, onSelect: () => nav.tab('/collection') },
          { label: 'ホーム', icon: <HomeIcon size={19} />, onSelect: () => nav.tab('/') },
        ]}
      />
    </Screen>
  )
}
