// ⑧ 作品一覧（/collection）。タブ。
// 上の切り替えボタンで種類を絞り込む（?category=種類）。
// その下の年のタブ（すべて・作品のある年。新しい年が左）と月のチップ（すべて・選んだ年の、作品のある月）で、見る範囲を選ぶ（?month=）。
//   ?month=2026-10 … その月の作品だけを 3 列に並べる。省くか、その種類の作品が無い月なら、いちばん新しい月（はじめに開いたとき）
//   ?month=2026    … その年の作品を、月ごとの見出しで区切って全部並べる（月のチップの「すべて」）
//   ?month=all     … 全部の作品を、月ごとの見出しで区切って並べる（年のタブの「すべて」。月のチップは出さない）
// 年のタブを押すと、その年のいちばん新しい月。作品名の下には作ったときの年齢（「5さい 4か月」）を出す。
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

/** 作成日の新しい順の作品を、作った月が変わるところで区切る */
function byMonth(items: Artwork[]) {
  const months: { key: string; label: string; items: Artwork[] }[] = []
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

export default function Collection() {
  const [params, setParams] = useSearchParams()
  const nav = useNav()
  const [menu, setMenu] = useState(false)
  const category = (params.get('category') as Tab | null) ?? 'all'
  const list = useArtworks({ category, sort: 'made' })

  const counts = new Map(list.data?.categories.map((c) => [c.id, c.count]))
  const items = list.data?.items ?? []
  const current = TABS.find((t) => t.value === category)
  const months = byMonth(items)
  // 年（"2026"）ごとの、いちばん新しい月。作品のある年だけ、新しい順
  const yearOf = (key: string) => key.slice(0, 4)
  const years = months.filter((m, i) => i === 0 || yearOf(months[i - 1].key) !== yearOf(m.key))
  // 見る範囲：全部・ある年の全部・ある月。URL の値が使えなければ（その種類の作品が無い月・年）、いちばん新しい月
  const wanted = params.get('month')
  const showAll = wanted === 'all'
  const wholeYear = !showAll && years.some((y) => yearOf(y.key) === wanted) ? wanted : null
  const month = showAll || wholeYear ? null : (months.find((m) => m.key === wanted) ?? months[0])
  const year = showAll ? null : (wholeYear ?? (month ? yearOf(month.key) : null))
  const monthsOfYear = months.filter((m) => yearOf(m.key) === year)
  const shown = showAll ? months : wholeYear ? monthsOfYear : month ? [month] : []
  const selectedChip = useRef<HTMLButtonElement>(null)

  // 選んでいる月のチップが見えるようにする（URL で古い月を開いたときなど）
  useEffect(() => {
    selectedChip.current?.scrollIntoView({ block: 'nearest', inline: 'center' })
  }, [month?.key, wholeYear])

  /** URL の種類（category）と月（month）を変える。履歴は増やさない */
  const go = (next: { category?: Tab; month?: string }) => {
    const c = next.category ?? category
    const m = next.month ?? params.get('month')
    setParams({ ...(c !== 'all' ? { category: c } : {}), ...(m ? { month: m } : {}) }, { replace: true })
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
        <Segmented<Tab>
          label="作品の種類"
          options={TABS}
          value={category}
          onChange={(value) => go({ category: value })}
        />
        <p className="count-caption">
          {current?.label}　{counts.get(category) ?? 0}点
        </p>

        <div style={{ marginTop: 12 }}>
          {list.isPending ? (
            <div className="grid-3">
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
            shown.length > 0 && (
              <div style={{ opacity: list.isPlaceholderData ? 0.55 : 1, transition: 'opacity .2s' }}>
                <div className="collection-years" role="tablist" aria-label="作った年">
                  <button
                    type="button"
                    role="tab"
                    aria-selected={showAll}
                    className={`collection-year${showAll ? ' selected' : ''}`}
                    onClick={() => go({ month: 'all' })}
                  >
                    すべて
                  </button>
                  {years.map((y) => {
                    const selected = yearOf(y.key) === year
                    return (
                      <button
                        key={y.key}
                        type="button"
                        role="tab"
                        aria-selected={selected}
                        className={`collection-year num${selected ? ' selected' : ''}`}
                        onClick={() => go({ month: y.key })}
                      >
                        {splitLabel(y.label)[0]}
                      </button>
                    )
                  })}
                </div>
                {year && (
                  <div className="collection-months" role="tablist" aria-label="作った月">
                    <button
                      ref={wholeYear ? selectedChip : undefined}
                      type="button"
                      role="tab"
                      aria-selected={!!wholeYear}
                      className={`collection-chip${wholeYear ? ' selected' : ''}`}
                      onClick={() => go({ month: year })}
                    >
                      すべて
                      <small className="num">{monthsOfYear.reduce((n, m) => n + m.items.length, 0)}</small>
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
                          className={`collection-chip num${selected ? ' selected' : ''}`}
                          onClick={() => go({ month: m.key })}
                        >
                          {splitLabel(m.label)[1]}
                          <small>{m.items.length}</small>
                        </button>
                      )
                    })}
                  </div>
                )}

                {/* 見る範囲の月ごとに、見出しと 3 列。表示のアニメーションは、月をまたいで順に少しずつずらす */}
                {shown.map((m, i) => (
                  <section key={`${category}-${m.key}`} className="collection-month">
                    <h2 className="collection-month-label num">
                      {m.label}
                      <span className="collection-month-count">{m.items.length}点</span>
                    </h2>
                    <div className="grid-3">
                      {m.items.map((a, j) => (
                        <ArtworkThumb
                          key={a.id}
                          artwork={a}
                          index={shown.slice(0, i).reduce((n, s) => n + s.items.length, 0) + j}
                          showBadge
                          meta="age"
                        />
                      ))}
                    </div>
                  </section>
                ))}
              </div>
            )
          )}
        </div>
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
