// ⑧ 作品一覧（/collection）。タブ。
// 上の切り替えボタンで種類を絞り込む（?category=種類）。
import { useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import { useArtworks, type Category } from '../api'
import { ActionMenu, ArtworkThumb, NavBar, Screen, Segmented, ThumbSkeletons } from '../components'
import { MoreIcon, MuseumIcon, PlusIcon } from '../icons'
import { useNav } from '../nav'

type Tab = Category | 'all'

const TABS: { value: Tab; label: string }[] = [
  { value: 'all', label: 'すべて' },
  { value: 'drawing', label: '絵画' },
  { value: 'craft', label: '工作' },
  { value: 'photo', label: '写真' },
  { value: 'other', label: 'その他' },
]

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
            <div
              key={category}
              className="grid-3"
              style={{ opacity: list.isPlaceholderData ? 0.55 : 1, transition: 'opacity .2s' }}
            >
              {items.map((a, i) => (
                <ArtworkThumb key={a.id} artwork={a} index={i} showBadge />
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
