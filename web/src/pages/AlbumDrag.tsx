// ⑧ 作品一覧で、作品を長押しして持ち上げ、上のアルバムの棚へ運んで入れる（Collection.tsx が作品の並びを包む）。
//   長押し（PRESS_MS）… 作品が指にくっついて持ち上がる。棚は画面の上に貼りつく（下のほうの作品からでも届くように。Collection.tsx の AlbumShelf）
//   運んで離す       … 指の下の棚のアルバムに入れる（「新しく作る」なら、名前を入れて作ると同時に入れる）。アルバムの外で離すと何もしない
//   棚の左右の端へ寄せる … アルバムが多くて棚からはみ出していれば、棚が横に流れる（EDGE_PX・EDGE_SPEED）
// 長押しの前に指が動いたら、ふつうのスクロールとして何もしない。持ち上げたあとは画面をスクロールさせず、離したあとの「詳細を開く」も止める。
// iPhone の Safari はブラウザ標準のドラッグ＆ドロップが指では動かないので、指（Pointer Events）を自分で追う。
// 作品のカードは ArtworkThumb の data-artwork-id で見分け、アルバムは棚のカードの data-album-drop（NEW_ALBUM は「新しく作る」）で見分ける。
import { useEffect, useRef, useState, type ReactNode, type PointerEvent as ReactPointerEvent, type SyntheticEvent } from 'react'
import { createPortal } from 'react-dom'
import { useAlbumArtworks, useAlbums, useCreateAlbum, type Artwork } from '../api'
import { AlbumNameSheet, useToast } from '../components'
import './AlbumDrag.css'

/** これだけ押し続けたら持ち上げる（ms） */
const PRESS_MS = 420
/** 持ち上げる前に指がこれ以上動いたら、スクロールとみなしてやめる（px） */
const MOVE_TOLERANCE = 10
/** 棚の左右の端からこの幅に指が入ったら、棚を横に流す（px）と、その速さ（px / コマ） */
const EDGE_PX = 44
const EDGE_SPEED = 9
/** 「新しく作る」の落とし先の印（棚の data-album-drop） */
export const NEW_ALBUM = 'new'

/** 棚に知らせる、持ち上げている間のようす。over は指の下のアルバムの id（NEW_ALBUM は「新しく作る」）、無ければ null */
export interface DragState {
  over: string | null
}

interface Drag {
  artwork: Artwork
  /** 指の位置（.app の左上から） */
  x: number
  y: number
  over: string | null
}

/** 画像が読めない（ファイルが消えた）ときは、壊れた画像の印を出さずに色だけにする */
const hideBroken = (e: SyntheticEvent<HTMLImageElement>) => {
  e.currentTarget.style.visibility = 'hidden'
}

/** 画面の外枠（.app）。持ち上げた作品はここに重ねる（PC ではスマホの枠の中に出すため） */
const appRoot = () => document.querySelector<HTMLElement>('.app') ?? document.body

export function AlbumDrag({
  artworks,
  onChange,
  children,
}: {
  artworks: Artwork[]
  /** 持ち上げた・指の下のアルバムが変わった（state）、置いた・やめた（null） */
  onChange: (state: DragState | null) => void
  children: ReactNode
}) {
  const toast = useToast()
  const albums = useAlbums()
  const move = useAlbumArtworks()
  const create = useCreateAlbum()
  const [drag, setDrag] = useState<Drag | null>(null)
  // 「新しく作る」に落とした作品（名前のシートを出している間）
  const [creatingFor, setCreatingFor] = useState<Artwork | null>(null)

  // 押している間の情報（描き直しに関わらないので ref）。clientX・clientY は最後の指の位置（棚を横に流すのに使う）
  const press = useRef<{ id: string; pointerId: number; startX: number; startY: number; clientX: number; clientY: number; timer: number; lifted: boolean } | null>(null)
  // 持ち上げたあとの指の離し（click）で、詳細を開かないようにする
  const swallowClick = useRef(false)
  const latest = useRef({ artworks, albums: albums.data?.items ?? [], drag, onChange })
  latest.current = { artworks, albums: albums.data?.items ?? [], drag, onChange }

  /** 指の位置（画面の座標）を .app の中の座標にし、その下のアルバムを探す */
  const locate = (clientX: number, clientY: number) => {
    const box = appRoot().getBoundingClientRect()
    const target = document.elementFromPoint(clientX, clientY)?.closest<HTMLElement>('[data-album-drop]')
    return { x: clientX - box.left, y: clientY - box.top, over: target?.dataset.albumDrop ?? null }
  }

  /** 持ち上げている作品を動かす（指の下のアルバムが変わったら棚に知らせる） */
  const follow = (clientX: number, clientY: number) => {
    const at = locate(clientX, clientY)
    if (at.over !== latest.current.drag?.over) latest.current.onChange({ over: at.over })
    setDrag((d) => (d ? { ...d, ...at } : d))
  }

  const drop = (artwork: Artwork, over: string) => {
    if (over === NEW_ALBUM) return setCreatingFor(artwork)
    const album = latest.current.albums.find((a) => a.id === over)
    move.mutate(
      { albumId: over, add: [artwork.id] },
      {
        onSuccess: () => toast(`「${album?.name ?? 'アルバム'}」に入れました`),
        onError: (e) => toast(e.message),
      },
    )
  }

  const cancel = () => {
    if (press.current) window.clearTimeout(press.current.timer)
    press.current = null
  }

  // 押しているあいだだけ、画面全体の指の動きを見る
  useEffect(() => {
    const onMove = (e: PointerEvent) => {
      const p = press.current
      if (!p || e.pointerId !== p.pointerId) return
      p.clientX = e.clientX
      p.clientY = e.clientY
      if (!p.lifted) {
        if (Math.hypot(e.clientX - p.startX, e.clientY - p.startY) > MOVE_TOLERANCE) cancel()
        return
      }
      follow(e.clientX, e.clientY)
    }
    const finish = (e: PointerEvent, dropIt: boolean) => {
      const p = press.current
      if (!p || e.pointerId !== p.pointerId) return
      window.clearTimeout(p.timer)
      press.current = null
      const d = latest.current.drag
      if (p.lifted && d) {
        const over = dropIt ? locate(e.clientX, e.clientY).over : null
        if (over) drop(d.artwork, over)
        setDrag(null)
        latest.current.onChange(null)
        // 離した直後の click だけを止める（click が来なかったときのために、少しあとで戻す）
        window.setTimeout(() => (swallowClick.current = false), 400)
      }
    }
    const onUp = (e: PointerEvent) => finish(e, true)
    const onCancel = (e: PointerEvent) => finish(e, false)
    // 持ち上げたあとは画面をスクロールさせない（touchmove を止めると、ブラウザが指を横取りしない）
    const onTouchMove = (e: TouchEvent) => {
      if (press.current?.lifted && e.cancelable) e.preventDefault()
    }
    // 長押しで出るメニュー（Android の「リンクを開く」など）を出さない
    const onContextMenu = (e: Event) => {
      if (press.current) e.preventDefault()
    }
    window.addEventListener('pointermove', onMove)
    window.addEventListener('pointerup', onUp)
    window.addEventListener('pointercancel', onCancel)
    window.addEventListener('touchmove', onTouchMove, { passive: false })
    window.addEventListener('contextmenu', onContextMenu)
    return () => {
      window.removeEventListener('pointermove', onMove)
      window.removeEventListener('pointerup', onUp)
      window.removeEventListener('pointercancel', onCancel)
      window.removeEventListener('touchmove', onTouchMove)
      window.removeEventListener('contextmenu', onContextMenu)
      cancel()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 最新の値は latest から読む
  }, [])

  // 持ち上げている間、指が棚の左右の端にあれば、棚を横に流す（流れたぶん、指の下のアルバムも変わる）
  const lifted = !!drag
  useEffect(() => {
    if (!lifted) return
    let frame = 0
    const tick = () => {
      frame = requestAnimationFrame(tick)
      const p = press.current
      const track = document.querySelector<HTMLElement>('.album-shelf-track')
      if (!p?.lifted || !track) return
      const box = track.getBoundingClientRect()
      if (p.clientY < box.top - 12 || p.clientY > box.bottom + 12) return
      const step = p.clientX < box.left + EDGE_PX ? -EDGE_SPEED : p.clientX > box.right - EDGE_PX ? EDGE_SPEED : 0
      if (!step) return
      const before = track.scrollLeft
      track.scrollLeft += step
      if (track.scrollLeft !== before) follow(p.clientX, p.clientY)
    }
    frame = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(frame)
    // eslint-disable-next-line react-hooks/exhaustive-deps -- 持ち上げている間だけ回す
  }, [lifted])

  const onPointerDown = (e: ReactPointerEvent) => {
    if (e.button !== 0 || press.current) return
    const card = (e.target as Element).closest<HTMLElement>('[data-artwork-id]')
    const id = card?.dataset.artworkId
    if (!id) return
    const { clientX, clientY, pointerId } = e
    const timer = window.setTimeout(() => {
      const p = press.current
      const artwork = latest.current.artworks.find((a) => a.id === id)
      if (!p || !artwork) return
      p.lifted = true
      swallowClick.current = true
      navigator.vibrate?.(12)
      const at = locate(p.clientX, p.clientY)
      setDrag({ artwork, ...at })
      latest.current.onChange({ over: at.over })
    }, PRESS_MS)
    press.current = { id, pointerId, startX: clientX, startY: clientY, clientX, clientY, timer, lifted: false }
  }

  return (
    <>
      <div
        className={`album-drag-area${drag ? ' is-dragging' : ''}`}
        onPointerDown={onPointerDown}
        // 持ち上げたあとの click（詳細を開く）を、作品のリンクに届く前に止める
        onClickCapture={(e) => {
          if (!swallowClick.current) return
          swallowClick.current = false
          e.preventDefault()
          e.stopPropagation()
        }}
        // マウスで押して動かしたとき、ブラウザ標準の画像のドラッグを始めない
        onDragStart={(e) => e.preventDefault()}
      >
        {children}
      </div>

      {drag &&
        createPortal(
          <div className="album-drag-ghost" style={{ left: drag.x, top: drag.y }} aria-hidden="true">
            <span style={{ background: drag.artwork.tint }}>
              <img src={drag.artwork.thumb_url} alt="" onError={hideBroken} />
            </span>
          </div>,
          appRoot(),
        )}

      <AlbumNameSheet
        open={!!creatingFor}
        onClose={() => setCreatingFor(null)}
        title="新しいアルバム"
        submitLabel="作って入れる"
        busy={create.isPending}
        error={create.error?.message}
        onSubmit={(name) =>
          creatingFor &&
          create.mutate(
            { name, artworkIds: [creatingFor.id] },
            {
              onSuccess: (album) => {
                toast(`「${album.name}」を作って入れました`)
                setCreatingFor(null)
              },
            },
          )
        }
      />
    </>
  )
}
