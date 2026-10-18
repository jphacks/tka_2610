// ⑧ 作品一覧（/collection）。タブ。
// 上の切り替えボタンで種類を絞り込む（?category=種類）。
// 作成日の新しい順の作品を、作った月ごとの見出し（「2026年 10月」）で区切って 3 列に並べ、作品名の下に作ったときの年齢（「5さい 4か月」）を出す。
// 月と年齢の文字は Rust が作る（month_key・month_label・age_month_label）。誕生日が無ければ年齢の代わりに日付。
import { useState } from 'react'
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

export default function Collection() {
  const [params, setParams] = useSearchParams()
  const nav = useNav()
  const [menu, setMenu] = useState(false)
  const category = (params.get('category') as Tab | null) ?? 'all'
  const list = useArtworks({ category, sort: 'made' })

  const counts = new Map(list.data?.categories.map((c) => [c.id, c.count]))
  const items = list.data?.items ?? []
  const current = TABS.find((t) => t.value === category)

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
          onChange={(value) => setParams(value === 'all' ? {} : { category: value }, { replace: true })}
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
            <div key={category} style={{ opacity: list.isPlaceholderData ? 0.55 : 1, transition: 'opacity .2s' }}>
              {byMonth(items).map((month) => (
                <section key={month.key} className="collection-month">
                  <h2 className="collection-month-label num">{month.label}</h2>
                  <div className="grid-3">
                    {month.items.map((a) => (
                      // 表示のアニメーションは、月をまたいで一覧の順に少しずつずらす
                      <ArtworkThumb key={a.id} artwork={a} index={items.indexOf(a)} showBadge meta="age" />
                    ))}
                  </div>
                </section>
              ))}
            </div>
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
