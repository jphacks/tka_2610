// ⑫ 模様替え（/home/edit?room=おへやの id）。push で開く（おへやの「模様替え」・おうちの中の「⋯」から）。
// おへや（年齢ごとの部屋）は ?room= で選ぶ（省くと今の年齢のおへや）。配置の読み書きも、作品を足すのもそのおへや。
// 斜め上から見た家の家具や作品を、ドラッグで動かす・回す・消す・足す。変えた配置は、最後の操作から 600 ms 後に自動で保存する。
//
// 3D とドラッグは HomeEditScene（three/ の遅延読み込みの中）、置けるかどうかの判定と操作は three/ の placement（three.js を使わない）。
// この画面は、下書きの配置（draft）・元に戻す・自動保存・追加のシートを受け持つ。
//   - 保存は useSaveLayout（PUT /api/home/layout）。400（置き方がおかしい）はサーバーの文言をお知らせに出し、下書きをサーバーの配置に戻す
//   - 保存していない変更がある間（dirty）は、/api/museum の新しい配置で下書きを上書きしない（作品のモデルの情報だけ使う）
//   - 作品を足すときは、保存を済ませてから POST /api/artworks/{id}/display（置き場所はサーバーが選ぶ）→ 取り直した配置を下書きにする
//   - 作品が載った家具を消すと、作品も下書きから消える（保存するとサーバーが「飾っていない」に戻す）。確認は出さず、元に戻すで戻せる
//   - テーマ（壁紙と床材）は catalog.themes から選ぶ。下書きの rooms[選んだ部屋].wall / floor を変えるだけで、ほかの操作と同じく元に戻せて自動で保存される
//   - 部屋（house.rooms にある部屋だけ。今はリビングだけなので切り替えは出ない）を選ぶと、カメラがその部屋へ寄り、テーマ・家具の追加・作品の追加はその部屋に入る
//     （作品は POST /display の本文 { room_id } で送り、その部屋に空きが無ければ 409）。切り替えると、選んでいる物とドラッグはやめる。
//     物は自分の部屋の中でだけ動かせる（部屋をまたぐ移動はしない）。house の無い古いサーバーでは部屋の切り替えを出さない（リビングだけ）
// PC の広い画面では、鑑賞モードと同じくスマホの枠をやめてウィンドウいっぱいに広げる（ドラッグしやすいように。HomeEdit.css）。
// 右上の「鑑賞モードへ」から ⑪ 鑑賞モードへ進める（PC でもスマホでも出す。スマホではタッチで歩ける）。
import { Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useSearchParams } from 'react-router-dom'
import {
  ApiError,
  saveLayoutOnLeave,
  useArtworks,
  useDisplay,
  useMuseum,
  useSaveLayout,
  type Artwork,
  type CatalogAsset,
  type FloorFinish,
  type HomeTheme,
  type Layout,
  type RoomId,
  type WallFinish,
} from '../api'
import { ArtworkThumb, GlassButton, Screen, Segmented, Sheet, ThumbSkeletons, useToast } from '../components'
import { BackIcon, PlusIcon, RotateIcon, ThemeIcon, TrashIcon, UndoIcon, WalkIcon } from '../icons'
import { useNav } from '../nav'
import {
  HomeEditScene,
  StageShell,
  addFurniture,
  hasHouseModel,
  houseRoomsOf,
  namesFromSlots,
  removeObject,
  rotateObject,
  sizesFromSlots,
} from '../three'
import './HomeEdit.css'

/** 最後の操作から保存までの待ち時間（ミリ秒） */
const SAVE_DELAY = 600
/** 元に戻せる回数 */
const UNDO_LIMIT = 30
/** 「回す」で回す角度（90°） */
const QUARTER = Math.PI / 2

type SaveState = 'idle' | 'saving' | 'saved' | 'error'
type SheetTab = 'furniture' | 'artwork'

const SHEET_TABS: { value: SheetTab; label: string }[] = [
  { value: 'furniture', label: '家具' },
  { value: 'artwork', label: '作品' },
]

/** 部屋の切り替えに出す名前と並び（house.rooms にある部屋だけ出す） */
const ROOM_TABS: { value: RoomId; label: string }[] = [
  { value: 'hub', label: '中央' },
  { value: 'left', label: '左' },
  { value: 'right', label: '右' },
  { value: 'front', label: '前' },
]

/** テーマのシートに出す壁紙・床材の名前 */
const WALL_LABEL: Record<WallFinish, string> = {
  plaster: '白壁',
  oak: 'オーク',
  brick: 'レンガ',
  limestone: '石材',
  nordic_chalk: '白い塗り壁',
  sage_limewash: 'セージの塗り壁',
  mushroom_limewash: 'マッシュルーム色の塗り壁',
  warm_cream: 'クリームの塗り壁',
  soft_brick: '淡いレンガ',
}
const FLOOR_LABEL: Record<FloorFinish, string> = {
  oak: 'オーク',
  limestone: '石材',
  white_oak: 'ホワイトオーク',
  pale_ash: 'アッシュ',
  warm_walnut: 'ウォールナット',
  carrara_marble: '白大理石',
  nero_marble: '黒大理石',
}

const meters = (n: number) => n.toFixed(2)

export default function HomeEdit() {
  const [params] = useSearchParams()
  const roomParam = params.get('room')
  // 鑑賞モードと違い、取り直しの間隔は付けない（編集中の配置をサーバーの値で上書きしないため）
  const museum = useMuseum({ roomId: roomParam })
  // 保存先のおへや（?room= を省いたときは、サーバーが選んだおへや）
  const ageRoom = museum.data?.room ?? null
  const ageRoomId = ageRoom?.id ?? roomParam
  const artworks = useArtworks({ sort: 'recent' })
  const save = useSaveLayout(ageRoomId)
  const display = useDisplay()
  const nav = useNav()
  const toast = useToast()

  const [ready, setReady] = useState(false)
  const [draft, setDraft] = useState<Layout | null>(null)
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [invalidReason, setInvalidReason] = useState<string | null>(null)
  const [dirty, setDirty] = useState(false)
  const [undo, setUndo] = useState<Layout[]>([])
  const [saveState, setSaveState] = useState<SaveState>('idle')
  const [sheetOpen, setSheetOpen] = useState(false)
  const [sheetTab, setSheetTab] = useState<SheetTab>('furniture')
  const [themeOpen, setThemeOpen] = useState(false)
  /** 選んでいる部屋（カメラ・テーマ・追加の先） */
  const [room, setRoom] = useState<RoomId>('hub')
  // 作品を飾る通信の間は、配置を触れないようにする（サーバーの配置と下書きがずれないように）
  const [busy, setBusy] = useState(false)

  // 保存の処理（タイマーや window のイベントから呼ぶ）は、描画を待たずに最新の値を読むので ref にも持つ
  const draftRef = useRef<Layout | null>(null)
  const ageRoomIdRef = useRef(ageRoomId)
  ageRoomIdRef.current = ageRoomId
  const dirtyRef = useRef(false)
  /** 操作のたびに 1 増やす。保存中に次の操作があったかを見分ける */
  const versionRef = useRef(0)
  const timerRef = useRef(0)
  const inFlightRef = useRef<Promise<void> | null>(null)
  /** 飾った作品を、取り直した配置の中で選ぶ（作品の id） */
  const selectAfterSync = useRef<string | null>(null)
  const latest = useRef({ mutateAsync: save.mutateAsync, refetch: museum.refetch })
  useLayoutEffect(() => {
    latest.current = { mutateAsync: save.mutateAsync, refetch: museum.refetch }
  })

  const setDraftNow = useCallback((layout: Layout) => {
    draftRef.current = layout
    setDraft(layout)
  }, [])

  const setClean = useCallback(() => {
    dirtyRef.current = false
    setDirty(false)
  }, [])

  /** 保存していない変更を、すぐに保存する。保存中なら、それが終わってから */
  const flush = useCallback(async (): Promise<void> => {
    window.clearTimeout(timerRef.current)
    timerRef.current = 0
    while (inFlightRef.current) await inFlightRef.current
    const layout = draftRef.current
    if (!dirtyRef.current || !layout) return
    const version = versionRef.current
    setSaveState('saving')
    const run = latest.current
      .mutateAsync(layout)
      .then(
        (saved) => {
          // 保存中に次の操作が無ければ、サーバーが整えた配置（向きの丸めなど）を下書きにする
          if (versionRef.current === version) {
            setClean()
            setDraftNow(saved.layout)
            setSaveState('saved')
          }
        },
        async (error: unknown) => {
          setSaveState('error')
          if (error instanceof ApiError && error.status === 400) {
            // 置き方がおかしい：サーバーの文言（どの家具かが書いてある）を出して、サーバーの配置に戻す
            toast(error.message)
            setClean()
            setUndo([])
            setInvalidReason(null)
            const fresh = await latest.current.refetch()
            if (fresh.data) setDraftNow(fresh.data.layout)
          } else {
            toast(error instanceof Error ? error.message : '保存できませんでした')
          }
        },
      )
      .finally(() => {
        inFlightRef.current = null
      })
    inFlightRef.current = run
    await run
  }, [setClean, setDraftNow, toast])

  const flushRef = useRef(flush)
  useLayoutEffect(() => {
    flushRef.current = flush
  })

  /** 下書きを layout に変えて、600 ms 後に保存する（その間に次の操作があれば、そこから数え直す） */
  const changeDraft = useCallback(
    (layout: Layout) => {
      setDraftNow(layout)
      dirtyRef.current = true
      setDirty(true)
      versionRef.current += 1
      setSaveState('saving')
      window.clearTimeout(timerRef.current)
      // requestAnimationFrame ではなく setTimeout（裏のタブでも保存が止まらないように）
      timerRef.current = window.setTimeout(() => void flushRef.current(), SAVE_DELAY)
    },
    [setDraftNow],
  )

  /** 操作で下書きを変えた：今の下書きを元に戻すに積んでから変える */
  const commit = useCallback(
    (next: Layout) => {
      const previous = draftRef.current
      if (previous) setUndo((u) => [...u, previous].slice(-UNDO_LIMIT))
      changeDraft(next)
    },
    [changeDraft],
  )

  // サーバーの配置を下書きにする（保存していない変更がある間は上書きしない）
  useEffect(() => {
    const data = museum.data
    if (!data || dirtyRef.current) return
    setDraftNow(data.layout)
    const artworkId = selectAfterSync.current
    const placed = artworkId ? data.layout.objects.find((o) => o.kind === 'artwork' && o.artworkId === artworkId) : undefined
    if (placed) {
      selectAfterSync.current = null
      setSelectedId(placed.id)
    }
  }, [museum.data, setDraftNow])

  // 画面を離れるときは、待たずにすぐ保存する。タブを閉じる・再読み込みするときは keepalive で送る
  useEffect(() => {
    const onHide = () => {
      if (dirtyRef.current && draftRef.current) saveLayoutOnLeave(ageRoomIdRef.current, draftRef.current)
    }
    window.addEventListener('pagehide', onHide)
    return () => {
      window.removeEventListener('pagehide', onHide)
      if (timerRef.current || dirtyRef.current) void flushRef.current()
    }
  }, [])

  const data = museum.data
  const catalog = data?.catalog
  const house = data?.house ?? null
  // 部屋の切り替え：house.rooms にある部屋だけ（古いサーバーではリビングだけなので出さない）
  const houseRooms = data ? houseRoomsOf(data) : []
  const roomTabs = ROOM_TABS.filter((t) => houseRooms.some((r) => r.id === t.value))
  const currentRoom: RoomId = roomTabs.some((t) => t.value === room) ? room : 'hub'
  const roomName = roomTabs.length > 1 ? (houseRooms.find((r) => r.id === currentRoom)?.name ?? 'リビング') : (ageRoom?.name ?? 'おへや')
  const nameOf = useMemo(() => namesFromSlots(data?.slots ?? []), [data?.slots])
  // 作品の実寸（置ける大きさの判定に使う。分からない作品は置き場所の枠そのものの大きさとして判定する）
  const sizeOf = useMemo(() => sizesFromSlots(data?.slots ?? []), [data?.slots])
  const selected = (selectedId && draft?.objects.find((o) => o.id === selectedId)) || null
  const selectedName = !selected
    ? null
    : selected.kind === 'furniture'
      ? (catalog?.assets.find((a) => a.id === selected.assetId)?.name_ja ?? '家具')
      : (data?.slots.find((s) => s.id === selected.id)?.artwork?.title ?? '作品')

  /**
   * 選んだ物を 90° 回す（R キーとツールバー）。回して面や部屋からはみ出す分は内側へ寄せる。
   * ほかの物と重なって置けなくなるなら、理由を出して回さない
   */
  const rotate = () => {
    const layout = draftRef.current
    if (!layout || !catalog || !selected || busy) return
    const result = rotateObject(layout, catalog, selected.id, QUARTER, { nameOf, sizeOf, house })
    if (result.ok) commit(result.layout)
    else toast(result.reason)
  }

  /** 選んだ物を消す（Delete / Backspace キーとツールバー）。家具なら上の作品も一緒に */
  const remove = () => {
    const layout = draftRef.current
    if (!layout || !selected || busy) return
    commit(removeObject(layout, selected.id))
    setSelectedId(null)
  }

  const undoLast = () => {
    const previous = undo[undo.length - 1]
    if (!previous || busy) return
    setUndo(undo.slice(0, -1))
    changeDraft(previous)
  }

  const openSheet = () => {
    setSheetOpen(true)
    // 飾っていない作品の一覧が最新になるよう、保存を済ませておく
    void flush()
  }

  /**
   * テーマを選んだ：選んでいる部屋の下書きの壁紙と床材を変える（3D はその場で変わり、600 ms 後に保存する）。
   * ほかの部屋はそのまま。シートは開いたままにして見比べられるようにする
   */
  const chooseTheme = (theme: HomeTheme) => {
    const layout = draftRef.current
    if (!layout || busy) return
    const current = layout.rooms[currentRoom]
    if (!current || (current.wall === theme.wall && current.floor === theme.floor)) return
    commit({ ...layout, rooms: { ...layout.rooms, [currentRoom]: { ...current, wall: theme.wall, floor: theme.floor } } })
  }

  /** 部屋を切り替える：カメラがその部屋へ寄る。選んでいる物と置けない理由の表示はやめる（ドラッグは HomeEditScene がやめる） */
  const changeRoom = (next: RoomId) => {
    if (next === currentRoom) return
    setRoom(next)
    setSelectedId(null)
    setInvalidReason(null)
  }

  /** 家具を、選んでいる部屋の空いている場所に足す（部屋の中心から渦巻き状に探す。出入口の前は避ける） */
  const addFurnitureOf = (asset: CatalogAsset) => {
    const layout = draftRef.current
    if (!layout || !catalog) return
    const added = addFurniture(layout, catalog, asset.id, currentRoom, { sizeOf, house })
    if (!added) {
      toast(`${roomName}に置く場所がありません`)
      return
    }
    commit(added.layout)
    setSelectedId(added.id)
    setSheetOpen(false)
  }

  const addArtwork = async (artwork: Artwork) => {
    setSheetOpen(false)
    setBusy(true)
    try {
      await flush()
      if (dirtyRef.current) {
        toast('保存できませんでした。もう一度試してください')
        return
      }
      selectAfterSync.current = artwork.id
      // 置き場所はサーバーが選ぶ（選んでいる部屋の空いている天板。house の無い古いサーバーには部屋を送らない）。
      // 成功すると、おうち・配置・作品の一覧を取り直す
      // 置き場所はこのおへやの中（作品の年齢のおへやだけが候補なので、違う年齢の作品は一覧に出さない）
      await display.mutateAsync({ id: artwork.id, display: true, roomId: ageRoomId ?? undefined })
    } catch (error) {
      selectAfterSync.current = null
      // 409 は「飾る場所がいっぱいです…」（選んだ部屋に空きが無いときも。ほかの部屋には置かない）
      toast(error instanceof Error ? error.message : '飾れませんでした')
    } finally {
      setBusy(false)
    }
  }

  const placedArtworkIds = useMemo(
    () => new Set(draft?.objects.flatMap((o) => (o.kind === 'artwork' ? [o.artworkId] : [])) ?? []),
    [draft],
  )
  // 足せる作品：このおへやの年齢の、飾っていない作品
  const hiddenArtworks = (artworks.data?.items ?? []).filter(
    (a) => !a.displayed && !placedArtworkIds.has(a.id) && (!ageRoom || a.age_at_made === ageRoom.age),
  )

  const saveLabel =
    saveState === 'error'
      ? '保存できませんでした'
      : dirty || saveState === 'saving'
        ? '保存中…'
        : saveState === 'saved'
          ? '保存しました'
          : ''
  const locked = sheetOpen || themeOpen || busy
  const finish = draft?.rooms[currentRoom]

  return (
    <Screen className="edit-screen">
      <StageShell
        className="edit-stage"
        ready={ready || (!!data && !hasHouseModel(data))}
        label="おうちを読み込んでいます…"
        overlay={
          <>
            <div className="stage-top">
              <GlassButton label="戻る" onClick={() => nav.back(ageRoomId ? `/rooms/${ageRoomId}` : '/')}>
                <BackIcon size={20} strokeWidth={2.2} />
              </GlassButton>
              <span className="stage-title glass">模様替え</span>
              <button
                type="button"
                className="edit-pill glass"
                onClick={() => nav.push(ageRoomId ? `/museum/walk?room=${ageRoomId}` : '/museum/walk')}
              >
                <WalkIcon size={17} />
                鑑賞モードへ
              </button>
            </div>

            <div className="edit-bottom">
              {roomTabs.length > 1 && (
                <div className="edit-rooms glass">
                  <Segmented label="部屋" options={roomTabs} value={currentRoom} onChange={changeRoom} />
                </div>
              )}
              <div className={`edit-status glass${invalidReason ? ' invalid' : ''}`} role="status">
                <span className="label">
                  {invalidReason ??
                    (selectedName ? `${selectedName}　ドラッグで動かす` : `${roomName}　家具や作品をタップして選ぶ`)}
                </span>
                {saveLabel && (
                  <button
                    type="button"
                    className={`edit-save${saveState === 'error' ? ' error' : ''}`}
                    disabled={saveState !== 'error'}
                    onClick={() => void flush()}
                  >
                    {saveLabel}
                  </button>
                )}
              </div>
              <div className="edit-toolbar glass" role="toolbar" aria-label="模様替えの操作">
                <button type="button" className="edit-tool" disabled={busy || !draft} onClick={openSheet}>
                  <PlusIcon size={21} strokeWidth={2} />
                  追加
                </button>
                <button
                  type="button"
                  className="edit-tool"
                  disabled={busy || !draft || !catalog?.themes.length}
                  onClick={() => setThemeOpen(true)}
                >
                  <ThemeIcon size={21} />
                  テーマ
                </button>
                <button type="button" className="edit-tool" disabled={busy || !selected} onClick={rotate}>
                  <RotateIcon size={21} />
                  回す
                </button>
                <button type="button" className="edit-tool" disabled={busy || !selected} onClick={remove}>
                  <TrashIcon size={21} />
                  消す
                </button>
                <button type="button" className="edit-tool" disabled={busy || undo.length === 0} onClick={undoLast}>
                  <UndoIcon size={21} />
                  元に戻す
                </button>
              </div>
            </div>
          </>
        }
      >
        {data && draft && (
          <Suspense fallback={null}>
            <HomeEditScene
              museum={data}
              layout={draft}
              roomId={currentRoom}
              selectedId={selected ? selected.id : null}
              locked={locked}
              onSelect={setSelectedId}
              onCommit={commit}
              onPreview={setInvalidReason}
              onReject={toast}
              onRotate={rotate}
              onDelete={remove}
              onReady={() => setReady(true)}
            />
          </Suspense>
        )}
        {data && !hasHouseModel(data) && <div className="stage-fallback">家の 3D モデル (GLB) が見つかりません</div>}
      </StageShell>

      <Sheet open={sheetOpen} onClose={() => setSheetOpen(false)} title={roomTabs.length > 1 ? `追加（${roomName}）` : '追加'}>
        <div className="sheet-body">
          <Segmented label="追加するもの" options={SHEET_TABS} value={sheetTab} onChange={setSheetTab} />
          <div className="edit-sheet-list">
            {sheetTab === 'furniture' ? (
              <div className="edit-furniture">
                {(catalog?.assets ?? []).map((asset) => (
                  <button key={asset.id} type="button" className="edit-furniture-item pressable" onClick={() => addFurnitureOf(asset)}>
                    <span className="name">{asset.name_ja}</span>
                    <span className="size num">
                      {meters(asset.dimensions_meters[0])} × {meters(asset.dimensions_meters[2])} m
                    </span>
                    {asset.support && <span className="tag">作品を置ける</span>}
                  </button>
                ))}
              </div>
            ) : artworks.isPending ? (
              <div className="grid-3">
                <ThumbSkeletons />
              </div>
            ) : hiddenArtworks.length === 0 ? (
              <div className="empty">
                <p>
                  {ageRoom ? `${ageRoom.age}さいのときの、飾っていない作品はありません。` : '飾っていない作品はありません。'}
                  <br />
                  作品を追加すると、ここから飾れます。
                </p>
              </div>
            ) : (
              <div className="grid-3">
                {hiddenArtworks.map((artwork, i) => (
                  <ArtworkThumb key={artwork.id} artwork={artwork} index={i} onSelect={() => void addArtwork(artwork)} />
                ))}
              </div>
            )}
          </div>
        </div>
      </Sheet>

      <Sheet open={themeOpen} onClose={() => setThemeOpen(false)} title={roomTabs.length > 1 ? `テーマ（${roomName}）` : 'テーマ'}>
        <div className="sheet-body">
          <div className="edit-themes" role="radiogroup" aria-label="壁紙と床材">
            {(catalog?.themes ?? []).map((theme) => {
              const current = finish?.wall === theme.wall && finish?.floor === theme.floor
              return (
                <button
                  key={theme.id}
                  type="button"
                  role="radio"
                  aria-checked={current}
                  className={`edit-theme pressable${current ? ' current' : ''}`}
                  disabled={busy}
                  onClick={() => chooseTheme(theme)}
                >
                  <span className="name">{theme.name}</span>
                  <span className="finish">
                    壁 {WALL_LABEL[theme.wall]}・床 {FLOOR_LABEL[theme.floor]}
                  </span>
                  {current && <span className="tag">使用中</span>}
                </button>
              )
            })}
          </div>
        </div>
      </Sheet>
    </Screen>
  )
}
