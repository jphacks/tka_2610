// ⑥ 作品の詳細の「アルバムに入れる」のシート。アルバムを押すたびに、その作品を入れる・外す（すぐ保存）。
// 下の「新しいアルバムを作る」は、このシートの中で名前を入れて、作ると同時にこの作品を入れる。
import { useEffect, useState, type FormEvent } from 'react'
import { useAlbumArtworks, useAlbums, useCreateAlbum, type Album } from '../api'
import { HeartIcon, PlusIcon } from '../icons'
import { Sheet } from './Sheet'
import { useToast } from './Toast'
import './AlbumSheet.css'

/** アルバムの名前の長さ（Rust の albums.rs の NAME_MAX と同じ） */
const NAME_MAX = 30

export function AlbumSheet({ open, onClose, artworkId }: { open: boolean; onClose: () => void; artworkId: string }) {
  const toast = useToast()
  const albums = useAlbums(open ? artworkId : undefined)
  const move = useAlbumArtworks()
  const create = useCreateAlbum()
  const [creating, setCreating] = useState(false)
  const [name, setName] = useState('')
  // 押してから一覧を取り直すまでの間も、押したとおりに見せる
  const [pending, setPending] = useState<Record<string, boolean>>({})

  useEffect(() => {
    if (!open) {
      setCreating(false)
      setName('')
      setPending({})
    }
  }, [open])

  const toggle = (album: Album) => {
    const inside = pending[album.id] ?? !!album.contains
    setPending((p) => ({ ...p, [album.id]: !inside }))
    move.mutate(
      { albumId: album.id, ...(inside ? { remove: [artworkId] } : { add: [artworkId] }) },
      {
        onError: (e) => {
          setPending((p) => ({ ...p, [album.id]: inside }))
          toast(e.message)
        },
      },
    )
  }

  const submit = (e: FormEvent) => {
    e.preventDefault()
    const trimmed = name.trim()
    if (!trimmed || create.isPending) return
    create.mutate(
      { name: trimmed, artworkIds: [artworkId] },
      {
        onSuccess: (album) => {
          toast(`「${album.name}」に入れました`)
          setCreating(false)
          setName('')
        },
        onError: (e) => toast(e.message),
      },
    )
  }

  return (
    <Sheet open={open} onClose={onClose} title={creating ? '新しいアルバム' : 'アルバムに入れる'}>
      {creating ? (
        <form className="sheet-body" onSubmit={submit}>
          <input
            className="input"
            aria-label="アルバムの名前"
            placeholder="例：4さいの夏、おじいちゃんにあげた"
            maxLength={NAME_MAX}
            value={name}
            onChange={(e) => setName(e.target.value)}
            autoFocus
            enterKeyHint="done"
          />
          <button type="submit" className="btn btn-filled" disabled={!name.trim() || create.isPending}>
            作ってこの作品を入れる
          </button>
          <button type="button" className="btn btn-gray" onClick={() => setCreating(false)}>
            もどる
          </button>
        </form>
      ) : (
        <div className="sheet-body">
          <ul className="album-sheet-list" aria-busy={albums.isPending}>
            {albums.data?.items.map((album) => {
              const inside = pending[album.id] ?? !!album.contains
              return (
                <li key={album.id}>
                  <button type="button" className="album-sheet-row pressable" aria-pressed={inside} onClick={() => toggle(album)}>
                    <span className="album-sheet-cover" style={album.cover_tint ? { background: album.cover_tint } : undefined}>
                      {album.cover_url ? <img src={album.cover_url} alt="" onError={(e) => { e.currentTarget.style.visibility = 'hidden' }} /> : album.built_in && <HeartIcon size={16} />}
                    </span>
                    <span className="album-sheet-name">
                      {album.name}
                      <small className="num">{album.count}点</small>
                    </span>
                    <span className={`album-sheet-check${inside ? ' on' : ''}`} aria-hidden="true" />
                  </button>
                </li>
              )
            })}
          </ul>
          <button type="button" className="btn btn-outline" onClick={() => setCreating(true)}>
            <PlusIcon size={18} />
            新しいアルバムを作る
          </button>
        </div>
      )}
    </Sheet>
  )
}
