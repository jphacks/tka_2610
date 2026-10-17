// ② ホーム（/）。タブ。
// 上に 3D の博物館、下に最近の作品。
import { Suspense, useEffect, useState } from 'react'
import { useArtworks, useMuseum } from '../api'
import { ArtworkThumb, GlassButton, NavBar, Screen, TLink, ThumbSkeletons, useToast } from '../components'
import { BellIcon, ChevronRight } from '../icons'
import { useNav } from '../nav'
import { HeroScene, StageShell, warmUp3D } from '../three'
import './Home.css'

export default function Home() {
  const museum = useMuseum()
  const recent = useArtworks({ sort: 'recent', limit: 6 })
  const nav = useNav()
  const toast = useToast()
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (museum.data) warmUp3D(museum.data.model_url)
  }, [museum.data])

  const name = museum.data?.name ?? 'はるのミュージアム'
  const initial = (museum.data?.owner_name ?? 'は').slice(0, 1)
  const items = recent.data?.items ?? []

  return (
    <Screen tabbar>
      <NavBar
        large
        eyebrow={museum.data?.today_label ?? ' '}
        title={name}
        right={
          <>
            <button className="icon-btn" aria-label="お知らせ" onClick={() => toast('新しいお知らせはありません')}>
              <BellIcon size={21} />
            </button>
            <TLink to="/settings" kind="tab" className="avatar" aria-label="マイページ">
              {initial}
            </TLink>
          </>
        }
      />

      <StageShell
        className="home-hero"
        ready={ready || museum.data?.model_url === null}
        overlay={
          <>
            <div className="hero-scrim" />
            <div className="hero-text">
              <p>
                たくさんの作品が、
                <br />
                ここに集まっています。
              </p>
              <small className="num">{museum.data ? `${museum.data.displayed_count}点を展示中` : ' '}</small>
            </div>
            <GlassButton label="博物館に入る" className="hero-go" onClick={() => nav.push('/museum')}>
              <ChevronRight size={22} strokeWidth={2.2} />
            </GlassButton>
          </>
        }
      >
        {museum.data && (
          <Suspense fallback={null}>
            <div style={{ position: 'absolute', inset: 0 }} onClick={() => nav.push('/museum')}>
              <HeroScene museum={museum.data} onReady={() => setReady(true)} />
            </div>
          </Suspense>
        )}
      </StageShell>

      <div className="page">
        <div className="section-head">
          <h2>最近の作品</h2>
          {items.length > 0 && (
            <TLink to="/collection" kind="tab" className="btn-plain">
              すべて見る
            </TLink>
          )}
        </div>

        {recent.isPending ? (
          <div className="grid-3">
            <ThumbSkeletons />
          </div>
        ) : items.length === 0 ? (
          <div className="empty">
            <p>
              まだ作品がありません。
              <br />
              絵や工作を撮って、最初の一点を飾りましょう。
            </p>
            <button className="btn btn-outline btn-small" onClick={() => nav.modal('/add')}>
              作品を追加
            </button>
          </div>
        ) : (
          <div className="grid-3">
            {items.map((a, i) => (
              <ArtworkThumb key={a.id} artwork={a} index={i} showBadge />
            ))}
          </div>
        )}
      </div>
    </Screen>
  )
}
