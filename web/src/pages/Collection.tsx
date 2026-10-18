// ⑧ 作品一覧（/collection）。タブ。
// 上から、種類の切り替え（?category=種類）・年の切り替え・（年を選んだときだけ）月のダイヤルで、見る範囲を絞り込む（?month=）。
// 月のダイヤル（MonthScroller）は横にスクロールして、真ん中の枠に止まった月を選ぶ（押すと、その月が真ん中へすべって選ばれる）。
//   省く      … すべて。全部の作品を、作成日の新しい順に見出し無しで 3 列に並べる（はじめに開いたとき）
//   2026      … その年の作品を、月ごとの見出しで区切って並べる（年を押したとき・月のダイヤルの「すべて」）
//   2026-10   … その月の作品だけを 3 列に並べる
// その種類の作品が無い年・月が URL にあれば、すべてにする（以前の ?month=all も、すべて）。
// 並びのすぐ上に、いま見ている範囲と点数を 1 行で出す（「工作・2026年 10月　2点」）。作品名の下には作ったときの年齢（「5さい 4か月」）。
// 月と年齢の文字は Rust が作る（month_key・month_label・age_month_label）。誕生日が無ければ年齢の代わりに日付。
import { useCallback, useLayoutEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useArtworks, type Artwork, type Category } from '../api'
import { ActionMenu, ArtworkThumb, NavBar, Screen, Segmented, ThumbSkeletons } from '../components'
import { MoreIcon, RainbowIcon, PlusIcon } from '../icons'
import { useNav } from '../nav'
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
      el.scrollTo({ left, behavior: first.current ? 'auto' : 'smooth' })
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

export default function Collection() {
  const [params, setParams] = useSearchParams()
  const nav = useNav()
  const [menu, setMenu] = useState(false)
  const category = (params.get('category') as Tab | null) ?? 'all'
  const list = useArtworks({ category, sort: 'made' })

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
  const go = (next: { category?: Tab; range?: string | null }) => {
    const c = next.category ?? category
    const r = next.range === undefined ? params.get('month') : next.range
    setParams({ ...(c !== 'all' ? { category: c } : {}), ...(r ? { month: r } : {}) }, { replace: true })
  }

  return (
    <Screen tabbar>
      <NavBar
        large
        title="作品一覧"
        right={
          <button className="icon-btn" aria-label="メニュー" onClick={() => setMenu(true)}>
            <MoreIcon size={21} />
          </button>
        }
      />
      <div className="page">
        <Segmented<Tab> label="作品の種類" options={TABS} value={category} onChange={(value) => go({ category: value })} />

        {list.isPending ? (
          <div className="grid-3 collection-body">
            <ThumbSkeletons count={9} />
          </div>
        ) : items.length === 0 ? (
          <div className="empty">
            <p>{category === 'all' ? 'まだ作品がありません。' : 'この種類の作品はまだありません。'}</p>
            <button className="btn btn-outline btn-small" onClick={() => nav.modal('/add')}>
              作品を追加
            </button>
          </div>
        ) : (
          <div className={list.isPlaceholderData ? 'collection-body stale' : 'collection-body'}>
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
                  {y}
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

            <p className="collection-scope" aria-live="polite">
              <span>{scopeLabel}</span>
              <span className="num">{shownCount}点</span>
            </p>

            {month || !year ? (
              // すべて・1 か月：見出し無しで並べる
              <div key={`${category}-${month?.key ?? 'all'}`} className="grid-3">
                {(month ? month.items : items).map((a, i) => (
                  <ArtworkThumb key={a.id} artwork={a} index={i} showBadge meta="age" />
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
                    <div className="grid-3">
                      {m.items.map((a, j) => (
                        <ArtworkThumb key={a.id} artwork={a} index={before + j} showBadge meta="age" />
                      ))}
                    </div>
                  </section>
                )
              })
            )}
          </div>
        )}
      </div>

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: '作品を追加', icon: <PlusIcon size={19} />, onSelect: () => nav.modal('/add') },
          { label: 'memoriaのマップ', icon: <RainbowIcon size={19} />, onSelect: () => nav.tab('/map') },
        ]}
      />
    </Screen>
  )
}
