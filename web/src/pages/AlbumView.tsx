// アルバムの画面（/collection/albums/:id、push）。⑧ 作品一覧の上の棚から開く。id は UUID か "favorites"（お気に入り）。
// 入っている作品を、作品一覧と同じ並べ方（作った日の新しい順・2 列）で出す。
// 「作品を選ぶ」で、全部の作品からチェックを付け外しして、まとめて入れる・外す（お気に入りなら、ハートが付く・外れる）。
// 右上の「⋯」で名前を変える・アルバムを削除（お気に入りには無い）。アルバムを消しても、作品は消えない。
import { useEffect, useState } from 'react'
import { useParams } from 'react-router-dom'
import { useAlbum, useAlbumArtworks, useArtworks, useDeleteAlbum, useRenameAlbum } from '../api'
import { ActionMenu, AlbumNameSheet, ArtworkThumb, NavBar, Screen, Sheet, ThumbSkeletons, useToast } from '../components'
import { BackIcon, GalleryIcon, HeartIcon, MoreIcon, PencilIcon, PlusIcon, TrashIcon } from '../icons'
import { useNav } from '../nav'
import './AlbumView.css'

export default function AlbumView() {
  const { id = '' } = useParams()
  const nav = useNav()
  const toast = useToast()
  const album = useAlbum(id)
  const list = useArtworks({ album: id, sort: 'made' })
  const rename = useRenameAlbum(id)
  const remove = useDeleteAlbum()
  const [picking, setPicking] = useState(false)
  const [menu, setMenu] = useState(false)
  const [renaming, setRenaming] = useState(false)
  const [confirmDelete, setConfirmDelete] = useState(false)

  const name = album.data?.name ?? ''
  const builtIn = album.data?.built_in ?? id === 'favorites'
  const items = list.data?.items ?? []
  const missing = album.isError || list.isError

  return (
    <Screen className="album-screen">
      <NavBar
        large
        title={name || 'アルバム'}
        eyebrow={album.data ? <span className="num">{album.data.count}点</span> : undefined}
        left={
          <button type="button" className="btn-plain album-back" onClick={() => nav.back('/collection')}>
            <BackIcon size={18} strokeWidth={2.2} />
            作品一覧
          </button>
        }
        right={
          !builtIn && album.data ? (
            <button type="button" className="btn-plain album-more" aria-label="アルバムのメニュー" onClick={() => setMenu(true)}>
              <MoreIcon size={22} />
            </button>
          ) : undefined
        }
      />
      <div className="page album-page">
        {missing ? (
          <div className="collection-empty" role="alert">
            <GalleryIcon size={30} />
            <h2>アルバムを読み込めませんでした</h2>
            <p>消されたか、接続がうまくいっていません。</p>
            <button type="button" className="btn btn-outline btn-small" onClick={() => nav.back('/collection')}>作品一覧へもどる</button>
          </div>
        ) : list.isPending ? (
          <div className="collection-grid" aria-label="Loading…" aria-busy="true">
            <ThumbSkeletons count={4} />
          </div>
        ) : items.length === 0 ? (
          <div className="collection-empty">
            {builtIn ? <HeartIcon size={30} /> : <GalleryIcon size={30} />}
            <h2>まだ作品が入っていません</h2>
            <p>{builtIn ? 'ハートを付けた作品が、ここに入ります。' : '作品を選んで、このアルバムにまとめましょう。'}</p>
            <button type="button" className="btn btn-outline btn-small" onClick={() => setPicking(true)}>
              作品を選ぶ
            </button>
          </div>
        ) : (
          <>
            <div className="album-toolbar">
              <button type="button" className="btn btn-outline btn-small" onClick={() => setPicking(true)}>
                <PlusIcon size={16} />
                作品を選ぶ
              </button>
            </div>
            <div className={list.isPlaceholderData ? 'collection-grid album-stale' : 'collection-grid'} aria-busy={list.isFetching}>
              {items.map((a, i) => (
                <ArtworkThumb key={a.id} artwork={a} index={i} showBadge meta="age" gallery />
              ))}
            </div>
          </>
        )}
      </div>

      <ArtworkPicker open={picking} onClose={() => setPicking(false)} albumId={id} albumName={name} inside={items.map((a) => a.id)} />

      <ActionMenu
        open={menu}
        onClose={() => setMenu(false)}
        items={[
          { label: '名前を変える', icon: <PencilIcon size={19} />, onSelect: () => setRenaming(true) },
          { label: 'アルバムを削除', icon: <TrashIcon size={19} />, destructive: true, onSelect: () => setConfirmDelete(true) },
        ]}
      />

      <AlbumNameSheet
        open={renaming}
        onClose={() => setRenaming(false)}
        title="アルバムの名前"
        initial={name}
        submitLabel="保存する"
        busy={rename.isPending}
        error={rename.error?.message}
        onSubmit={(next) =>
          rename.mutate(next, {
            onSuccess: () => {
              toast('名前を変えました')
              setRenaming(false)
            },
          })
        }
      />

      <Sheet open={confirmDelete} onClose={() => setConfirmDelete(false)} title={`「${name}」を削除しますか？`}>
        <p className="hint album-delete-hint">入っている作品は消えません。</p>
        <div className="sheet-body">
          <button
            type="button"
            className="btn btn-destructive"
            disabled={remove.isPending}
            onClick={() =>
              remove.mutate(id, {
                onSuccess: () => {
                  toast('アルバムを削除しました')
                  setConfirmDelete(false)
                  nav.back('/collection')
                },
                onError: (e) => toast(e.message),
              })
            }
          >
            アルバムを削除
          </button>
          <button type="button" className="btn btn-gray" onClick={() => setConfirmDelete(false)}>
            キャンセル
          </button>
        </div>
      </Sheet>
    </Screen>
  )
}

/**
 * 「作品を選ぶ」のシート。全部の作品（作った日の新しい順）にチェックを付け外しして、「完了」でまとめて入れる・外す。
 * 開いたときは、今アルバムに入っている作品（inside）にチェックが付いている
 */
function ArtworkPicker({
  open,
  onClose,
  albumId,
  albumName,
  inside,
}: {
  open: boolean
  onClose: () => void
  albumId: string
  albumName: string
  inside: string[]
}) {
  const toast = useToast()
  const all = useArtworks({ sort: 'made' })
  const move = useAlbumArtworks()
  const [chosen, setChosen] = useState<Set<string>>(new Set())
  const insideKey = inside.join(',')

  // 開くたびに、今入っている作品から選び直す
  useEffect(() => {
    if (open) setChosen(new Set(inside))
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 開いたとき（と、入っている作品が変わったとき）だけ
  }, [open, insideKey])

  const add = [...chosen].filter((a) => !inside.includes(a))
  const removed = inside.filter((a) => !chosen.has(a))
  const changed = add.length + removed.length > 0

  const toggle = (artworkId: string) =>
    setChosen((before) => {
      const next = new Set(before)
      if (next.has(artworkId)) next.delete(artworkId)
      else next.add(artworkId)
      return next
    })

  const done = () => {
    if (!changed) return onClose()
    move.mutate(
      { albumId, add, remove: removed },
      {
        onSuccess: () => {
          toast(albumName ? `「${albumName}」を更新しました` : 'アルバムを更新しました')
          onClose()
        },
        onError: (e) => toast(e.message),
      },
    )
  }

  return (
    <Sheet open={open} onClose={onClose} title="作品を選ぶ">
      <p className="hint album-picker-hint num">{chosen.size}点を選んでいます</p>
      <div className="album-picker-grid" aria-busy={all.isPending}>
        {all.isPending ? (
          <ThumbSkeletons count={6} />
        ) : (
          all.data?.items.map((a, i) => (
            <ArtworkThumb key={a.id} artwork={a} index={i} meta="age" selected={chosen.has(a.id)} onSelect={() => toggle(a.id)} />
          ))
        )}
      </div>
      <div className="sheet-body">
        <button type="button" className="btn btn-filled" disabled={move.isPending} onClick={done}>
          {changed ? `完了（${add.length ? `${add.length}点を入れる` : ''}${add.length && removed.length ? '・' : ''}${removed.length ? `${removed.length}点を外す` : ''}）` : '完了'}
        </button>
      </div>
    </Sheet>
  )
}
