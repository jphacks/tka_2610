// ⑧ 作品一覧（/collection）。タブ。
// 上から、種類の切り替え（?category=種類）・年の切り替え・（年を選んだときだけ）月のチップで、見る範囲を絞り込む（?month=）。
//   省く      … すべて。全部の作品を、作成日の新しい順に見出し無しで 3 列に並べる（はじめに開いたとき）
//   2026      … その年の作品を、月ごとの見出しで区切って並べる（年を押したとき・月のチップの「すべて」）
//   2026-10   … その月の作品だけを 3 列に並べる
// その種類の作品が無い年・月が URL にあれば、すべてにする（以前の ?month=all も、すべて）。
// 並びのすぐ上に、いま見ている範囲と点数を 1 行で出す（「工作・2026年 10月　2点」）。作品名の下には作ったときの年齢（「5さい 4か月」）。
// 月と年齢の文字は Rust が作る（month_key・month_label・age_month_label）。誕生日が無ければ年齢の代わりに日付。
import { useEffect, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useArtworks, type Artwork, type Category } from '../api'
import { ActionMenu, ArtworkThumb, NavBar, Screen, Segmented, ThumbSkeletons } from '../components'
import { MoreIcon, MuseumIcon, PlusIcon } from '../icons'
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

  // 選んでいる月のチップが見えるようにする（URL で古い月を開いたときなど）
  const selectedChip = useRef<HTMLButtonElement>(null)
  useEffect(() => {
    selectedChip.current?.scrollIntoView({ block: 'nearest', inline: 'center' })
  }, [month?.key, year])

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

            {/* 月：年を選んだときだけ。その年の、作品のある月 */}
            {year && (
              <div className="collection-months" role="tablist" aria-label="作った月">
                <button
                  ref={!month ? selectedChip : undefined}
                  type="button"
                  role="tab"
                  aria-selected={!month}
                  className={`collection-chip${!month ? ' selected' : ''}`}
                  onClick={() => go({ range: year })}
                >
                  <span className="collection-chip-name">すべて</span>
                  <span className="collection-chip-count num">{yearCount}点</span>
                </button>
                {monthsOfYear.map((m) => {
                  const selected = m.key === month?.key
                  return (
                    <button
                      key={m.key}
                      ref={selected ? selectedChip : undefined}
                      type="button"
                      role="tab"
                      aria-selected={selected}
                      className={`collection-chip${selected ? ' selected' : ''}`}
                      onClick={() => go({ range: m.key })}
                    >
                      <span className="collection-chip-name num">{splitLabel(m.label)[1]}</span>
                      <span className="collection-chip-count num">{m.items.length}点</span>
                    </button>
                  )
                })}
              </div>
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
          { label: 'おうちのマップ', icon: <MuseumIcon size={19} />, onSelect: () => nav.tab('/map') },
        ]}
      />
    </Screen>
  )
}
