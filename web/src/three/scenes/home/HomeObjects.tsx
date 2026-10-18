// 配置 JSON（/api/museum の layout）のとおりに、家具と作品を置く部品。家具と作品を描くのは、どの 3D 画面でもここだけ。
//
//   部屋：家具と床の作品の位置は、所属する部屋（roomId）の中心を原点にした「部屋の中の位置」。部屋ごとに
//         `ROOM_<部屋>` のグループを部屋の中心（house.rooms[].origin。placement.ts の roomOrigin）へ平行移動し、その中に
//         配置 JSON の位置のまま置く（世界座標 = origin + position。Rust の world_of と同じ）。家具の上の作品は家具のグループの子なので、
//         部屋の平行移動は家具に 1 回だけ掛かる。house が無い古いサーバーでは、どの部屋の中心も原点。
//   家具：catalog の GLB を複製して、`FURN_<object id>` のグループ（userData.objectId）に置く。影を落とし・受ける。
//   作品：家具の上に載せる作品は、その家具のグループの子にして、載せている面（天板・本棚の段。catalog の surfaces）の中心に置く。
//         配置 JSON の作品の位置は「親の家具を回す前の向き」で書いてあるので、子にすれば家具と一緒に回る。
//         床に置く作品は y = 0。グループの名前は `ARTWORK_<object id>`、userData.artworkId を付ける
//         （歩く画面の ArtworkPicker と、おうちの中で作品をクリックしたときに、どの作品かを見分ける）。
//         モデルの URL・種類・実寸は、Rust が計算した slots（object id で対応する）から取る。
//         大きさは、実寸（artwork.model_size）を置き場所の枠（面の art_fit、床なら FLOOR_ART_FIT）に作品の向きで収めた
//         拡縮率（placement.ts の displayScale。Rust の display_scale と同じ式で、slots の scale と一致する）。
//         下書きの配置で計算するので、模様替えで回した・載せ換えた作品も保存を待たずにその大きさになる。
//         実寸が分からない作品は、今までどおり枠 fit に収める（FittedModel の対角線の規則）。
//
// 物ごとに Suspense を分け、家の建物を先に表示する。GLB が載る・外れるたびと、置いた物の位置・向きが変わったとき
// （模様替えの後や、鑑賞モードの 3 秒ごとの取り直しで動いた配置が届いたとき）に、1 回にまとめて onReady を呼ぶ
// （歩く画面が当たり判定と影を作り直す）。
// スマホなど（pointer: coarse）では、カメラに近い作品 6 つだけを置く（作品の GLB は大きく、GPU のメモリを使うため）。
//
// 模様替えモード（HomeEditScene）では onObjectPointerDown と previewTransform を渡す：
//   onObjectPointerDown … 家具・作品を押したときに object id を知らせる（天板の上の作品を押したときは作品だけ。家具には伝えない）
//   previewTransform    … ドラッグ中の物を、配置 JSON の値の代わりにこの位置と向きで置く（家具を動かせば、上の作品も一緒に動く）。
//                         作品は親（parentId・surface）も差し替えるので、ほかの家具や床へ載せ換えている途中の作品は、
//                         新しい家具のグループの下（床なら床）に描く
// どちらも渡さない画面では、今までどおり（ポインタの当たり判定もしない）。選んだ物の印は HomeEditScene が床に板を敷いて出す
// （GLB のマテリアルは全部の物・全部の画面で共有しているので、色を付けて目印にしてはいけない）。
//
// memoryBadges を付けると、おもいで（写真・動画・声の記録。slots の artwork.memory_counts）のある作品の上に、小さな丸い印を
// drei の Html で出す（声があれば音符、無ければ動画か写真の印と数）。印を押すと、作品を押したのと同じ onSelect。おへや（HomeScene）で使う。

import { Suspense, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { useFrame, useThree, type ThreeEvent } from '@react-three/fiber'
import { Html, useGLTF } from '@react-three/drei'
import * as THREE from 'three'
import type { ArtworkObject, CatalogAsset, FurnitureObject, HomeCatalog, House, Layout, MemoryCounts, RoomId, SlotView, Vec3 } from '../../../api'
import { GalleryIcon, NoteIcon, VideoIcon } from '../../../icons'
import { FittedModel } from '../models'
import { FLOOR_ART_FIT, HUB, displayScale, roomOrigin, surfaceOf } from './placement'
import './HomeObjects.css'

/** 作品を置く数の既定値。スマホなど（指で操作する端末）は 6、それ以外は全部 */
const DEFAULT_MAX_ARTWORKS =
  typeof window !== 'undefined' && window.matchMedia?.('(pointer: coarse)').matches ? 6 : Infinity
/** カメラがこれ以上（m）動いたら、近い作品を選び直す */
const RESELECT_DISTANCE = 0.5

/**
 * 何度呼んでも、まとめて 1 回だけ fn を呼ぶ関数を返す。
 * requestAnimationFrame ではなく setTimeout にしているのは、タブが裏にあると rAF が止まり、
 * 当たり判定が作られないまま「読み込み中」が終わらなくなるため
 */
function useBatchedCallback(fn: (() => void) | undefined) {
  const latest = useRef(fn)
  useLayoutEffect(() => {
    latest.current = fn
  })
  const timer = useRef(0)
  useEffect(
    () => () => {
      clearTimeout(timer.current)
      // 0 に戻しておかないと、付け直したとき（StrictMode など）に二度と呼ばれなくなる
      timer.current = 0
    },
    [],
  )
  return useCallback(() => {
    if (timer.current) return
    timer.current = window.setTimeout(() => {
      timer.current = 0
      latest.current?.()
    }, 0)
  }, [])
}

interface Placed {
  object: ArtworkObject
  slot: SlotView
}

/**
 * ドラッグ中の物の仮の位置と向き（模様替えモード）。position は配置 JSON と同じ座標
 * （家具・床の作品は部屋の中の位置、天板の上の作品は親の家具から見た位置）。y は持ち上げる高さ（m）
 */
export interface PreviewTransform {
  id: string
  /** 作品の載せ換え先の家具の object id（床なら null）。省くと配置 JSON のまま */
  parentId?: string | null
  /** 作品の載せ換え先の面（天板は null か省く）。parentId を渡したときだけ使う */
  surface?: string | null
  /** 床へ載せ換えた作品の部屋（parentId が null のときだけ使う）。省くと配置 JSON の roomId（無ければリビング） */
  roomId?: RoomId
  position: Vec3
  rotationY: number
}

/** ドラッグ中の作品なら、親・面・位置・向きを仮の値に差し替える（y は持ち上げる高さなので配置 JSON には入れない） */
function withPreview(p: Placed, preview: PreviewTransform | null | undefined): Placed {
  if (!preview || preview.id !== p.object.id) return p
  const object: ArtworkObject = {
    ...p.object,
    position: [preview.position[0], 0, preview.position[2]],
    rotationY: preview.rotationY,
  }
  if (preview.parentId !== undefined) {
    object.parentId = preview.parentId ?? undefined
    object.surface = preview.surface ?? undefined
    if (preview.parentId === null && preview.roomId) object.roomId = preview.roomId
  }
  return { ...p, object }
}

/**
 * カメラに近い作品を max 個まで選ぶ。全部で max 個以下なら null（全部置く）。
 * 近さは slots の世界座標で測る（シーンをたどらずに済む）。カメラが少し動いたときだけ選び直す
 */
function useNearestArtworks(placed: Placed[], max: number): Set<string> | null {
  const camera = useThree((s) => s.camera)
  const limited = placed.length > max
  const [picked, setPicked] = useState<{ placed: Placed[]; ids: Set<string> } | null>(null)
  const last = useRef<THREE.Vector3 | null>(null)

  const pick = (from: THREE.Vector3) => {
    const distance = ([x, y, z]: Vec3) => (x - from.x) ** 2 + (y - from.y) ** 2 + (z - from.z) ** 2
    return new Set(
      placed
        .map((p) => ({ id: p.object.id, d: distance(p.slot.position) }))
        .sort((a, b) => a.d - b.d)
        .slice(0, max)
        .map((p) => p.id),
    )
  }

  useFrame(() => {
    if (!limited) return
    const moved = !last.current || camera.position.distanceTo(last.current) > RESELECT_DISTANCE
    if (!moved && picked?.placed === placed) return
    last.current = camera.position.clone()
    const ids = pick(camera.position)
    const same = picked?.placed === placed && picked.ids.size === ids.size && [...ids].every((id) => picked.ids.has(id))
    if (!same) setPicked({ placed, ids })
  })

  if (!limited) return null
  // 配置が変わった直後（まだ選び直していない）は、今のカメラの位置でその場で選ぶ
  return picked?.placed === placed ? picked.ids : pick(camera.position)
}

/** 家具 1 つの GLB。読み込んだら・外したら onMount を呼ぶ */
function FurnitureModel({ url, onMount }: { url: string; onMount: () => void }) {
  const { scene } = useGLTF(url, false, false)
  const object = useMemo(() => {
    const clone = scene.clone(true)
    clone.traverse((o) => {
      const mesh = o as THREE.Mesh
      if (mesh.isMesh) {
        mesh.castShadow = true
        mesh.receiveShadow = true
      }
      // 家具の中の部品どうしは動かないので、毎フレームの行列計算を省く（家具そのものはグループごと動かせる）
      o.updateMatrix()
      o.matrixAutoUpdate = false
    })
    return clone
  }, [scene])

  useLayoutEffect(() => {
    onMount()
    return onMount
  }, [object, onMount])

  return <primitive object={object} />
}

export function HomeObjects({
  layout,
  catalog,
  slots,
  house,
  onSelect,
  onReady,
  maxArtworks = DEFAULT_MAX_ARTWORKS,
  onObjectPointerDown,
  previewTransform,
  memoryBadges = false,
}: {
  layout: Layout
  catalog: HomeCatalog
  /** 作品の置き場所（/api/museum の slots）。作品のモデルの URL・種類・収める範囲をここから取る */
  slots: SlotView[]
  /** 部屋の定義（/api/museum の house）。部屋の中心（origin）へ部屋ごとのグループを動かす。無ければどの部屋も原点 */
  house?: House | null
  /** 渡すと作品をクリックできるようになる（おうちの中の画面） */
  onSelect?: (artworkId: string) => void
  /** 家具や作品の GLB が載った・外れたときと、置いた物の位置・向きが変わったとき（1 回にまとめて呼ぶ） */
  onReady?: () => void
  /** 置く作品の数の上限（カメラに近い順）。既定はスマホなどで 6、それ以外は全部 */
  maxArtworks?: number
  /** 模様替えモード：家具・作品を押したとき（object id）。渡すと物ごとにポインタの当たり判定をする */
  onObjectPointerDown?: (objectId: string, event: ThreeEvent<PointerEvent>) => void
  /** 模様替えモード：ドラッグ中の物の仮の位置と向き（配置 JSON の値の代わりに使う） */
  previewTransform?: PreviewTransform | null
  /** おもいでのある作品の上に印を出す（おへや） */
  memoryBadges?: boolean
}) {
  const notify = useBatchedCallback(onReady)
  const assets = useMemo(() => new Map(catalog.assets.map((a) => [a.id, a])), [catalog])

  const { furniture, placed } = useMemo(() => {
    const slotById = new Map(slots.map((s) => [s.id, s]))
    const furniture: { object: FurnitureObject; asset: CatalogAsset }[] = []
    const placed: Placed[] = []
    for (const object of layout.objects) {
      if (object.kind === 'furniture') {
        const asset = assets.get(object.assetId)
        if (asset) furniture.push({ object, asset })
      } else {
        // モデルの URL は slots にしかない。まだ slots に無い作品（保存前など）は置かない
        const slot = slotById.get(object.id)
        if (slot?.artwork) placed.push({ object, slot })
      }
    }
    return { furniture, placed }
  }, [layout, slots, assets])

  // 同じ id の物が動いた・回っただけでは GLB の載り外しが起きないので、位置と向きが変わったことをここで知らせる
  // （知らせないと、歩く画面の当たり判定と影が古い場所に残る）。文字列にして比べるので、同じ配置が届いても呼ばない
  // 部屋（roomId）と部屋の中心（house の origin）も入れる（部屋のグループが動くと、中の物の世界座標も変わるため）
  const transformsKey =
    layout.objects
      .map(
        (o) =>
          `${o.id}:${o.roomId ?? ''}:${o.kind === 'artwork' ? `${o.parentId ?? ''}/${o.surface ?? ''}` : o.assetId}:${o.position[0]},${o.position[2]},${o.rotationY}`,
      )
      .join('|') + `#${house?.rooms.map((r) => `${r.id}@${r.origin[0]},${r.origin[1]}`).join(',') ?? ''}`
  useEffect(() => {
    notify()
  }, [transformsKey, notify])

  const nearest = useNearestArtworks(placed, maxArtworks)
  // ドラッグ中の作品は、親・面・位置・向きを仮の値に差し替えてから家具ごとに分ける（載せ換え中の作品を新しい家具の下に描くため）
  const shown = (nearest ? placed.filter((p) => nearest.has(p.object.id)) : placed).map((p) => withPreview(p, previewTransform))
  const furnitureIds = new Set(furniture.map((f) => f.object.id))
  const onFurniture = (parentId: string) => shown.filter((p) => p.object.parentId === parentId)
  // 親の家具が見つからない作品（Rust が計算した世界座標に置く。部屋のグループには入れない）
  const orphans = shown.filter((p) => p.object.parentId && !furnitureIds.has(p.object.parentId))

  // 部屋ごとに、家具と床の作品を分ける（部屋のグループの中に、部屋の中の位置のまま置く）
  const rooms = new Map<RoomId, { furniture: typeof furniture; floor: Placed[] }>()
  const roomEntry = (id: RoomId) => {
    let entry = rooms.get(id)
    if (!entry) rooms.set(id, (entry = { furniture: [], floor: [] }))
    return entry
  }
  for (const f of furniture) roomEntry(f.object.roomId ?? HUB).furniture.push(f)
  for (const p of shown) if (!p.object.parentId) roomEntry(p.object.roomId ?? HUB).floor.push(p)

  useEffect(() => () => void (document.body.style.cursor = ''), [])
  const hover = (on: boolean) => (e: ThreeEvent<PointerEvent>) => {
    e.stopPropagation()
    document.body.style.cursor = on ? 'pointer' : ''
  }
  // クリックできるのは onSelect を渡したときだけ（渡さない画面では、ポインタの当たり判定もしない）
  const clickable = (artworkId: string) =>
    onSelect
      ? {
          onClick: (e: ThreeEvent<MouseEvent>) => {
            e.stopPropagation()
            onSelect(artworkId)
          },
          onPointerOver: hover(true),
          onPointerOut: hover(false),
        }
      : {}

  // 模様替えモードで、物を押したときに知らせる（渡さない画面では、ポインタの当たり判定もしない）
  const grabbable = (objectId: string) =>
    onObjectPointerDown
      ? {
          onPointerDown: (e: ThreeEvent<PointerEvent>) => {
            // 天板の上の作品を押したとき、親の家具や床には伝えない
            e.stopPropagation()
            onObjectPointerDown(objectId, e)
          },
        }
      : {}
  // ドラッグ中の物は、配置 JSON の値の代わりに仮の位置と向きを使う
  const preview = (id: string) => (previewTransform && previewTransform.id === id ? previewTransform : null)

  // 置いた後の大きさ（実寸が分からない作品は undefined で、FittedModel が枠 fit に収める）。fit は置き場所の枠
  const scaleOf = ({ slot }: Placed, fit: Vec3, rotationY: number) => {
    const size = slot.artwork.model_size
    return size ? displayScale({ size, custom: slot.artwork.model_kind === 'custom' }, fit, rotationY) : undefined
  }

  const artwork = ({ object, slot }: Placed, position: Vec3, rotationY: number, fit: Vec3, scale: number | undefined) => (
    <group
      key={`${object.id}-${object.artworkId}`}
      name={`ARTWORK_${object.id}`}
      userData={{ artworkId: slot.artwork.id, objectId: object.id }}
      position={position}
      rotation-y={rotationY}
      {...clickable(slot.artwork.id)}
      {...grabbable(object.id)}
    >
      <Suspense fallback={null}>
        <FittedModel
          url={slot.artwork.model_url}
          fit={fit}
          scale={scale}
          noUpscale={slot.artwork.model_kind === 'custom'}
          shadows
          onMount={notify}
        />
      </Suspense>
      {memoryBadges && (
        <MemoryBadge
          counts={slot.artwork.memory_counts}
          // 作品のてっぺんの少し上（実寸が分からない作品は枠の高さ）
          height={(slot.artwork.model_size && scale ? slot.artwork.model_size[1] * scale : fit[1]) + 0.12}
          onClick={onSelect ? () => onSelect(slot.artwork.id) : undefined}
        />
      )}
    </group>
  )

  const renderFurniture = ({ object, asset }: { object: FurnitureObject; asset: CatalogAsset }) => {
    const moving = preview(object.id)
    const at = moving ?? object
    return (
      <group
        key={object.id}
        name={`FURN_${object.id}`}
        userData={{ objectId: object.id }}
        // y は壁の家具の高さ（床の家具は 0）。ドラッグ中は持ち上げた高さ
        position={[at.position[0], moving ? moving.position[1] : object.position[1], at.position[2]]}
        rotation-y={at.rotationY}
        {...grabbable(object.id)}
      >
        <Suspense fallback={null}>
          <FurnitureModel url={asset.file_url} onMount={notify} />
        </Suspense>
        {onFurniture(object.id).map((p) => {
          // 位置・向き・面は、ドラッグ中なら仮の値（withPreview で差し替え済み）。持ち上げる高さだけ preview から
          const lift = preview(p.object.id)?.position[1] ?? 0
          const art = p.object
          // 位置は面の中心から。収める枠は面で決まる（Rust の art_fit と同じ値。棚の段では低くなる）
          const surface = surfaceOf(asset, art.surface)
          const [ax, ay, az] = surface?.anchor ?? [0, asset.dimensions_meters[1], 0]
          const fit = surface?.art_fit ?? p.slot.fit
          return artwork(
            p,
            [ax + art.position[0], ay + lift, az + art.position[2]],
            art.rotationY,
            fit,
            scaleOf(p, fit, art.rotationY),
          )
        })}
      </group>
    )
  }

  // 床の作品（下書きで床へ移した作品も）は、部屋のグループの中に部屋の中の位置で置き、床置きの枠に収める
  const renderFloorArtwork = (p: Placed) => {
    const lift = preview(p.object.id)?.position[1] ?? 0
    const at = p.object
    return artwork(p, [at.position[0], lift, at.position[2]], at.rotationY, FLOOR_ART_FIT, scaleOf(p, FLOOR_ART_FIT, at.rotationY))
  }

  return (
    <>
      {[...rooms].map(([roomId, entry]) => {
        const [ox, oz] = roomOrigin(house, roomId)
        return (
          <group key={roomId} name={`ROOM_${roomId}`} position={[ox, 0, oz]}>
            {entry.furniture.map(renderFurniture)}
            {entry.floor.map(renderFloorArtwork)}
          </group>
        )
      })}
      {/* 親の家具が見つからない作品は、Rust が計算した世界座標と拡縮率で置く */}
      {orphans.map((p) => artwork(p, p.slot.position, THREE.MathUtils.degToRad(p.slot.yaw), p.slot.fit, p.slot.scale ?? undefined))}
    </>
  )
}

/** おもいでのある作品の上の、小さな丸い印（声があれば音符、無ければ動画か写真の印と数）。おもいでが無ければ出さない */
function MemoryBadge({ counts, height, onClick }: { counts: MemoryCounts | undefined; height: number; onClick?: () => void }) {
  const total = counts ? counts.photo + counts.video + counts.audio : 0
  if (!counts || total === 0) return null
  const Icon = counts.audio > 0 ? NoteIcon : counts.video > 0 ? VideoIcon : GalleryIcon
  return (
    <Html position={[0, height, 0]} center zIndexRange={[10, 0]}>
      <button type="button" className={`memory-badge${counts.audio > 0 ? ' voice' : ''}`} aria-label={`おもいで ${total}`} onClick={onClick}>
        <Icon size={13} />
        <span className="num">{total}</span>
      </button>
    </Html>
  )
}
