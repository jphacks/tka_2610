// ⑧ 作品一覧（/collection）。タブ。
// いちばん上はアルバムの棚（AlbumShelf）。「新しく作る」・お気に入り・作ったアルバムを横に並べ、押すとアルバムの画面（AlbumView）へ。
// 見出し「アルバム」の横の矢印を押すと、棚をたたむ・開く（この端末に覚える）。
// 作品を長押しすると持ち上がり、上の棚のアルバムへ運んで入れられる（AlbumDrag）。運んでいる間、棚は画面の上に貼りつく。
// 上から、種類の切り替え（?category=種類）・年の切り替え・（年を選んだときだけ）月のダイヤルで、見る範囲を絞り込む（?month=）。
// 月のダイヤル（MonthScroller）は横にスクロールして、真ん中の枠に止まった月を選ぶ（押すと、その月が真ん中へすべって選ばれる）。
//   省く      … すべて。全部の作品を、作成日の新しい順に見出し無しで並べる（既定2列・切り替えで3列）（はじめに開いたとき）
//   2026      … その年の作品を、月ごとの見出しで区切って並べる（年を押したとき・月のダイヤルの「すべて」）
//   2026-10   … その月の作品だけを並べる
// その種類の作品が無い年・月が URL にあれば、すべてにする（以前の ?month=all も、すべて）。
// 並びのすぐ上に、いま見ている範囲と点数を 1 行で出す（「工作・2026年 10月　2点」）。作品名の下には作ったときの年齢（「5さい 4か月」）。
// 月と年齢の文字は Rust が作る（month_key・month_label・age_month_label）。誕生日が無ければ年齢の代わりに日付。
import { useCallback, useEffect, useLayoutEffect, useRef, useState, type SyntheticEvent } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useAlbums, useArtworks, useCreateAlbum, type Artwork, type Category } from '../api'
import { AlbumNameSheet, ArtworkThumb, NavBar, Screen, Segmented, ThumbSkeletons, TLink } from '../components'
import { BackIcon, GalleryIcon, HeartIcon, PlusIcon } from '../icons'
import { useNav } from '../nav'
import { AlbumDrag, NEW_ALBUM, type DragState } from './AlbumDrag'
import './Collection.css'

type Tab = Category | 'all'

const TABS: { value: Tab; label: string }[] = [
  { value: 'all', label: 'すべて' },
  { value: 'drawing', label: '絵画' },
  { value: 'craft', label: '工作' },
  { value: 'photo', label: '写真' },
  { value: 'other', label: 'その他' },
]

interface Month {
  /** "2026-10" */
  key: string
  /** "2026年 10月" */
  label: string
  items: Artwork[]
}

/** 作成日の新しい順の作品を、作った月が変わるところで区切る */
function byMonth(items: Artwork[]): Month[] {
  const months: Month[] = []
  for (const artwork of items) {
    const last = months[months.length - 1]
    if (last?.key === artwork.month_key) last.items.push(artwork)
    else months.push({ key: artwork.month_key, label: artwork.month_label, items: [artwork] })
  }
  return months
}

/** 月の見出し（「2026年 10月」）を、年（「2026年」）と月（「10月」）に分ける */
function splitLabel(label: string): [string, string] {
  const [year = '', month = label] = label.split(' ')
  return [year, month]
}

const yearOf = (key: string) => key.slice(0, 4)

/** スクロールが止まったとみなすまでの時間（ミリ秒）。指を離したあとの慣性のスクロールが終わるのを待つ */
const SETTLE_MS = 140

/**
 * 月のダイヤル。横にスクロールして、真ん中の枠（.month-lens）に止まった項目を選ぶ（onChange）。押すと、その項目を選ぶ。
 * 項目は 1 つずつぴたっと止まり（scroll-snap）、真ん中から離れるほど小さく薄く出す（--d に真ん中からの近さを入れる）。
 * value が変わったら（年を変えた・押した・URL で開いた）、その項目を真ん中へすべらせる。そのスクロールでは選び直さない
 */
function MonthScroller({
  items,
  value,
  onChange,
}: {
  items: { key: string; name: string; count: number }[]
  value: string
  onChange: (key: string) => void
}) {
  const track = useRef<HTMLDivElement>(null)
  // 自分で真ん中へ動かしている間は、止まっても選び直さない
  const steering = useRef(false)
  const timer = useRef<number | undefined>(undefined)
  const first = useRef(true)
  useEffect(() => () => window.clearTimeout(timer.current), [])
  const latest = useRef({ value, onChange, items })
  latest.current = { value, onChange, items }

  /** 項目ごとに、真ん中からの離れ具合（0 = 真ん中、1 = 端）を --d に入れる */
  const paint = useCallback(() => {
    const el = track.current
    if (!el) return
    const center = el.scrollLeft + el.clientWidth / 2
    for (const child of Array.from(el.children) as HTMLElement[]) {
      const d = Math.min(Math.abs(child.offsetLeft + child.offsetWidth / 2 - center) / (el.clientWidth / 2), 1)
      child.style.setProperty('--d', d.toFixed(3))
    }
  }, [])

  // 選んでいる項目を真ん中へ（はじめはすぐ、そのあとはすべらせる）。項目の並びが同じなら、描き直しのたびには動かさない
  const keys = items.map((it) => it.key).join(',')
  useLayoutEffect(() => {
    const el = track.current
    const child = el?.children[items.findIndex((it) => it.key === value)] as HTMLElement | undefined
    if (!el || !child) return
    const left = child.offsetLeft + child.offsetWidth / 2 - el.clientWidth / 2
    if (Math.abs(el.scrollLeft - left) >= 1) {
      steering.current = true
      el.scrollTo({ left, behavior: first.current || window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth' })
    }
    first.current = false
    paint()
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 並び（keys）が変わったときだけ
  }, [value, keys, paint])

  /** スクロールが止まった：自分で動かしたのでなければ、真ん中にいちばん近い項目を選ぶ */
  const settle = () => {
    const el = track.current
    if (!el) return
    if (steering.current) {
      steering.current = false
      return
    }
    const center = el.scrollLeft + el.clientWidth / 2
    let best = 0
    let bestDistance = Infinity
    Array.from(el.children).forEach((child, i) => {
      const c = child as HTMLElement
      const distance = Math.abs(c.offsetLeft + c.offsetWidth / 2 - center)
      if (distance < bestDistance) [best, bestDistance] = [i, distance]
    })
    const { items: list, value: current, onChange: change } = latest.current
    const key = list[best]?.key
    if (key && key !== current) change(key)
  }

  const onScroll = () => {
    requestAnimationFrame(paint)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(settle, SETTLE_MS)
  }

  return (
    <div className="month-scroller">
      <div className="month-lens" aria-hidden="true" />
      <div ref={track} className="month-track" role="tablist" aria-label="作った月" onScroll={onScroll}>
        {items.map((it) => {
          const selected = it.key === value
          return (
            <button
              key={it.key}
              type="button"
              role="tab"
              aria-selected={selected}
              className={`month-item${selected ? ' selected' : ''}`}
              onClick={() => onChange(it.key)}
            >
              <span className="month-item-name num">{it.name}</span>
              <span className="month-item-count num">{it.count}点</span>
            </button>
          )
        })}
      </div>
    </div>
  )
}

/** 表紙の画像が読めない（ファイルが消えた）ときは、壊れた画像の印を出さずに表紙の色だけにする */
const hideBroken = (e: SyntheticEvent<HTMLImageElement>) => {
  e.currentTarget.style.visibility = 'hidden'
}

/** アルバムの棚をたたんだかを覚える場所（この端末の localStorage。読めなくても、開いたまま使える） */
const FOLDED_KEY = 'collection.albums-folded'

function readFolded() {
  try {
    return localStorage.getItem(FOLDED_KEY) === '1'
  } catch {
    return false
  }
}

function writeFolded(folded: boolean) {
  try {
    if (folded) localStorage.setItem(FOLDED_KEY, '1')
    else localStorage.removeItem(FOLDED_KEY)
  } catch {
    /* 覚えられなくても、今の画面ではたためる */
  }
}

/**
 * アルバムの棚。先頭は「新しく作る」（名前を入れて作ると、そのアルバムの画面へ進む）、次にお気に入り、そのあとは新しく作った順。
 * 多ければ横にスクロールする。
 * 見出しの横の矢印で、棚をたたむ・開く（たたんだかは、この端末に覚える）。たたんでいても、作品を持ち上げている間は開く。
 * 作品を持ち上げている間（drag）は、画面の上に貼りつき、指の下のアルバム（drag.over）をふくらませる。カードの data-album-drop が落とし先の印
 */
function AlbumShelf({ drag }: { drag: DragState | null }) {
  const nav = useNav()
  const albums = useAlbums()
  const create = useCreateAlbum()
  const [creating, setCreating] = useState(false)
  const [folded, setFolded] = useState(readFolded)
  const open = !folded || !!drag
  const toggle = () => {
    setFolded(!folded)
    writeFolded(!folded)
  }

  return (
    <section className={`album-shelf${drag ? ' is-docked' : ''}${open ? '' : ' is-folded'}`} aria-labelledby="album-shelf-title">
      <div className="album-shelf-head">
        <h2 id="album-shelf-title" className="album-shelf-title">
          <button type="button" className="album-shelf-toggle" aria-expanded={open} aria-controls="album-shelf-body" onClick={toggle}>
            アルバム
            {albums.data && <span className="album-shelf-count num" aria-label={`${albums.data.items.length}こ`}>{albums.data.items.length}</span>}
            <BackIcon size={16} strokeWidth={2.4} className="album-shelf-arrow" aria-hidden="true" />
          </button>
        </h2>
        {open && <span className="album-shelf-hint">{drag ? (drag.over ? '離すと入れます' : 'ここへ運んで入れます') : '作品を長押しして、ここへ運べます'}</span>}
      </div>
      <div id="album-shelf-body" className="album-shelf-body" aria-hidden={!open}>
      <div className="album-shelf-track">
        <button
          type="button"
          className={`album-card album-card-new pressable${drag?.over === NEW_ALBUM ? ' is-over' : ''}`}
          data-album-drop={NEW_ALBUM}
          onClick={() => setCreating(true)}
        >
          <span className="album-card-cover"><PlusIcon size={24} /></span>
          <span className="album-card-name">新しく作る</span>
        </button>
        {albums.isPending
          ? [0, 1].map((i) => <span key={i} className="album-card"><span className="album-card-cover skeleton" /></span>)
          : albums.data?.items.map((album) => (
              <TLink
                key={album.id}
                to={`/collection/albums/${album.id}`}
                className={`album-card pressable${drag?.over === album.id ? ' is-over' : ''}`}
                data-album-drop={album.id}
              >
                <span className={`album-card-cover${album.built_in ? ' favorites' : ''}`} style={album.cover_tint ? { background: album.cover_tint } : undefined}>
                  {album.cover_url ? <img src={album.cover_url} alt="" loading="lazy" onError={hideBroken} /> : album.built_in ? <HeartIcon size={24} filled /> : <GalleryIcon size={24} />}
                  {album.built_in && album.cover_url && <span className="album-card-badge" aria-hidden="true"><HeartIcon size={12} filled /></span>}
                </span>
                <span className="album-card-name">{album.name}</span>
                <span className="album-card-count num">{album.count}点</span>
              </TLink>
            ))}
      </div>
      </div>
      <AlbumNameSheet
        open={creating}
        onClose={() => setCreating(false)}
        title="新しいアルバム"
        submitLabel="作る"
        busy={create.isPending}
        error={create.error?.message}
        onSubmit={(name) =>
          create.mutate(
            { name },
            {
              onSuccess: (album) => {
                setCreating(false)
                nav.push(`/collection/albums/${album.id}`)
              },
            },
          )
        }
      />
    </section>
  )
}

export default function Collection() {
  const [params, setParams] = useSearchParams()
  const nav = useNav()
  const category: Tab = TABS.find((tab) => tab.value === params.get('category'))?.value ?? 'all'
  const compact = params.get('view') === 'compact'
  const gridClass = `collection-grid${compact ? ' compact' : ''}`
  const list = useArtworks({ category, sort: 'made' })
  // 作品を持ち上げている間のようす（棚を貼りつけ、指の下のアルバムをふくらませる）
  const [drag, setDrag] = useState<DragState | null>(null)

  const items = list.data?.items ?? []
  const months = byMonth(items)
  // 作品のある年（"2026"）。新しい順
  const years = [...new Set(months.map((m) => yearOf(m.key)))]

  // 見る範囲。URL の年・月に、この種類の作品が無ければ「すべて」
  const wanted = params.get('month') ?? ''
  const month = months.find((m) => m.key === wanted) ?? null
  const year = month ? yearOf(month.key) : years.includes(wanted) ? wanted : null
  const monthsOfYear = year ? months.filter((m) => yearOf(m.key) === year) : []
  const yearCount = monthsOfYear.reduce((n, m) => n + m.items.length, 0)
  const shownCount = month ? month.items.length : year ? yearCount : items.length

  // いま見ている範囲の名前（「工作・2026年 10月」）
  const categoryLabel = TABS.find((t) => t.value === category)?.label
  const scope = month ? month.label : year ? splitLabel(monthsOfYear[0].label)[0] : 'すべての作品'
  const scopeLabel = category === 'all' ? scope : `${categoryLabel}・${scope}`


  /** URL の種類（category）と範囲（month）を変える。履歴は増やさない。range が null なら「すべて」 */
  const go = (next: { category?: Tab; range?: string | null; compact?: boolean }) => {
    const c = next.category ?? category
    const r = next.range === undefined ? params.get('month') : next.range
    setParams({ ...(c !== 'all' ? { category: c } : {}), ...(r ? { month: r } : {}), ...((next.compact ?? compact) ? { view: 'compact' } : {}) }, { replace: true })
  }

  return (
    <Screen tabbar className="collection-screen">
      <NavBar title="作品一覧" />
      <div className="page collection-page">
        <AlbumShelf drag={drag} />
        <div className="collection-filters">
        <Segmented<Tab> label="作品の種類" options={TABS} value={category} onChange={(value) => go({ category: value })} />
        </div>

        {list.isPending ? (
          <div className={`${gridClass} collection-body`} aria-label="Loading…" aria-busy="true">
            <ThumbSkeletons count={6} />
          </div>
        ) : list.isError ? (
          <div className="collection-empty" role="alert">
            <GalleryIcon size={30} />
            <h2>作品を読み込めませんでした</h2>
            <p>接続を確認して、もう一度お試しください。</p>
            <button type="button" className="btn btn-outline btn-small" disabled={list.isFetching} onClick={() => list.refetch()}>もう一度読み込む</button>
          </div>
        ) : items.length === 0 ? (
          <div className="collection-empty">
            <GalleryIcon size={30} />
            <h2>{category === 'all' ? 'まだ作品がありません' : 'この種類の作品はまだありません'}</h2>
            <p>作品の写真を撮るか、画像を選んで追加できます。</p>
            <button className="btn btn-outline btn-small" onClick={() => nav.modal('/add')}>
              作品を追加
            </button>
          </div>
        ) : (
          <AlbumDrag artworks={items} onChange={setDrag}>
          <div className={list.isPlaceholderData ? 'collection-body stale' : 'collection-body'} aria-busy={list.isFetching}>
            {/* 年：すべて・作品のある年。選んでいるものだけ塗る */}
            <div className="collection-years" role="tablist" aria-label="作った年">
              <button
                type="button"
                role="tab"
                aria-selected={!year}
                className={`collection-year${!year ? ' selected' : ''}`}
                onClick={() => go({ range: null })}
              >
                すべて
              </button>
              {years.map((y) => (
                <button
                  key={y}
                  type="button"
                  role="tab"
                  aria-selected={y === year}
                  className={`collection-year num${y === year ? ' selected' : ''}`}
                  onClick={() => go({ range: y })}
                >
                  {y}年
                </button>
              ))}
            </div>

            {/* 月：年を選んだときだけ。その年の「すべて」と、作品のある月を横にスクロールして選ぶ */}
            {year && (
              <MonthScroller
                items={[
                  { key: year, name: 'すべて', count: yearCount },
                  ...monthsOfYear.map((m) => ({ key: m.key, name: splitLabel(m.label)[1], count: m.items.length })),
                ]}
                value={month?.key ?? year}
                onChange={(key) => go({ range: key })}
              />
            )}

            <div className="collection-toolbar">
              <div className="collection-scope" aria-live="polite">
                <h2>{scopeLabel}</h2>
                <span className="num">{shownCount}点</span>
              </div>
              <div className="collection-density" role="group" aria-label="作品の表示サイズ">
                <button type="button" aria-pressed={!compact} onClick={() => go({ compact: false })}>2列</button>
                <button type="button" aria-pressed={compact} onClick={() => go({ compact: true })}>3列</button>
              </div>
            </div>

            {month || !year ? (
              // すべて・1 か月：見出し無しで並べる
              <div key={`${category}-${month?.key ?? 'all'}`} className={gridClass}>
                {(month ? month.items : items).map((a, i) => (
                  <ArtworkThumb key={a.id} artwork={a} index={i} showBadge meta="age" gallery />
                ))}
              </div>
            ) : (
              // 1 年分：月ごとに見出しで区切る。表示のアニメーションは、月をまたいで順に少しずつずらす
              monthsOfYear.map((m, i) => {
                const before = monthsOfYear.slice(0, i).reduce((n, s) => n + s.items.length, 0)
                return (
                  <section key={`${category}-${m.key}`} className="collection-month">
                    <h2 className="collection-month-label">
                      <span className="num">{splitLabel(m.label)[1]}</span>
                      <small className="num">{m.items.length}点</small>
                    </h2>
                    <div className={gridClass}>
                      {m.items.map((a, j) => (
                        <ArtworkThumb key={a.id} artwork={a} index={before + j} showBadge meta="age" gallery />
                      ))}
                    </div>
                  </section>
                )
              })
            )}
          </div>
          </AlbumDrag>
        )}
      </div>

    </Screen>
  )
}
