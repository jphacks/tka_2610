// ⑪ 鑑賞モード。家の中を一人称で歩き、飾っている作品を見る。
//
// ここでは部品を組み立てるだけにしている。それぞれの役割は walk/ と home/ の各ファイル：
//   walk/stagePreset.ts         はじめの位置・歩き方・カメラ・照明・当たり判定から外すもの（HOME_STAGE）
//   walk/stageMaterials.ts      ステージ（家の建物と家具）の材質と影を、この画面用に整える
//   walk/collision.ts           ステージの形から当たり判定を作る
//   walk/player.ts              歩く人の動き（重力・壁・段差）
//   walk/FirstPersonControls.tsx キーボードとマウスの操作（PC） → player → カメラ
//   walk/TouchControls.tsx      タッチの操作（スマホ。左の仮想スティックで歩き、右をなぞって見回す） → player → カメラ
//   walk/playerCamera.ts        カメラを目の位置に置く（2 つの操作で共通）
//   walk/inputMode.ts           どちらの操作にするか（isTouchDevice。画面が決めて touch で渡す）・仮想スティックの大きさ
//   walk/ArtworkPicker.tsx      照準の先にある作品を見つける（E / クリック / タップで作品カードを開く）
//   walk/lighting.tsx           照明・空・影・映り込み
//   walk/PostEffects.tsx        画面の仕上げ（隅の陰・光のにじみ・アンチエイリアス。PC だけ）
//   walk/ArtworkSpotlights.tsx  近くの作品を照らすスポットライト
//   walk/SharpTextures.tsx      床や作品を斜めから見てもぼやけないようにする
//   home/HomeObjects.tsx        配置 JSON のとおりに家具と作品を置く（ほかの 3D 画面と同じ部品）
//   home/HouseShells.tsx        家の建物を部屋ごとに置く（ほかの 3D 画面と同じ部品）
// 家の建物は部屋ごとの GLB（house.rooms[].model_url。Rust: home.rs の ROOM_DEFS）。リビングだけは
// museum.walk_model_url（サーバーの WALK_MODEL_PATH。ふだんは無い）があればそれを使う。house の無い古いサーバーでは model_url の 1 つ。
// 当たり判定は、建物（全部の部屋）と家具をまとめたグループ（stageRef）から作る。家具は後から 1 つずつ載るので、
// 建物を読み込んだときと、家具や作品が載る・外れるたびに（HomeObjects の onReady）作り直す。
// 歩き始められる（ready）のは、model_url のある部屋の建物が全部そろってから（まだ床の無い部屋へ歩いて落ちないように）。
// 壁紙と床材（テーマ）は MuseumModel が home/theme.ts で部屋ごとに当てる。テーマが変わったとき（画像を待ってから差し替えたときも）は
// onLoaded がもう一度呼ばれるので、材質を整え直し、当たり判定・影・映り込みも作り直す。
// ほかの画面と違い、手前の壁はカットせず（cutaway なし）、部屋ごとに天井の板を張り、部屋ごとにダウンライトを点ける
// （位置と大きさは house.rooms から。並べ方は walk/stagePreset.ts の roomLights）。映り込みはリビングの中から撮る。
//
// 操作は、PC では FirstPersonControls（クリックで Pointer Lock して歩き始め、Esc でやめる）、
// タッチの端末（touch。画面が walk/inputMode.ts の isTouchDevice で決めて渡す）では TouchControls。
// タッチでは Pointer Lock が無いので、歩き始める・やめるは画面が walking で決める（作品カードを開いている間は止まる）。
// どちらでも、歩いている間だけ毎フレーム描き（frameloop: always）、ほかは変化があったときだけ描く。
//
// タッチの端末では、軽い表示（lite）にする（スマホの GPU で、なめらかに歩けるように）：
//   - 画面の仕上げ（PostEffects：隅の陰 GTAO・光のにじみ・MSAA）を置かず、Canvas の antialias でふちを整える。
//     トーンマッピング（Neutral）と sRGB への変換は、PC では PostEffects の最後の OutputPass が、lite では描くときに renderer が、
//     同じ renderer の設定（onCreated）で行うので、色や明るさは PC とそろう（隅の陰と光のにじみが無い分だけ違う）
//   - 描画の細かさ（dpr）の上限を 1.5 → 1.25（重いときに PerformanceMonitor が 1 まで下げるのは同じ）
//   - 作品のスポットライトを 6 → 2 個、小さい部屋のダウンライトを 3 → 1 灯（stagePreset の smallLite。今の家はリビングだけなので 5 灯のまま）。
//     three.js はライトの数だけ画面の全部の点で計算するため
//   - 太陽の影の細かさを 2048 → 1024 px、映り込みの細かさを 128 → 64 px（どちらも作り直したときだけ撮るのは同じ）
// 作品の GLB を置く数は HomeObjects が端末（pointer: coarse）で決める（スマホは近い 6 つ）。

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import { Canvas, useThree } from '@react-three/fiber'
import { PerformanceMonitor } from '@react-three/drei'
import * as THREE from 'three'
import type { HouseRoom, Museum, RoomId } from '../../api'
import { getWalkPose, saveWalkPose } from '../walkPose'
import { HomeObjects } from './home/HomeObjects'
import { HouseShells, useShells } from './home/HouseShells'
import { houseBounds, houseRoomsOf, wallThicknessOf } from './home/house'
import { ArtworkPicker } from './walk/ArtworkPicker'
import { ArtworkSpotlights } from './walk/ArtworkSpotlights'
import { buildCollisionWorld } from './walk/collision'
import { FirstPersonControls } from './walk/FirstPersonControls'
import type { TouchStick } from './walk/inputMode'
import { MuseumDaylight, ReflectionCapture, StaticShadows } from './walk/lighting'
import { PostEffects } from './walk/PostEffects'
import { Player } from './walk/player'
import { CEILING_HEIGHT, HOME_STAGE, roomDownlights } from './walk/stagePreset'
import { SharpTextures } from './walk/SharpTextures'
import { createWalkMaterials } from './walk/stageMaterials'
import { TouchControls } from './walk/TouchControls'

/** 画面（pages/MuseumWalk.tsx）に知らせる状態 */
export interface WalkStatus {
  /** loading: ステージを読み込み中 / ready: 歩ける */
  phase: 'loading' | 'ready'
  /**
   * 操作を受け付けているか。PC はマウスが固定されているとき。
   * タッチは、画面が歩き始めさせていて（walking）、作品カードを開いていない（paused でない）とき
   */
  walking: boolean
  /** 照準の先にある（E / クリック / タップ・「見る」で見られる）作品 */
  aimedArtworkId: string | null
}

/** 影は動かないステージの分だけを、必要なときに描き直す（lighting.tsx の StaticShadows）。three.js 0.186 で使える PCF にする */
const SHADOWS = { type: THREE.PCFShadowMap, autoUpdate: false } as const
/** カメラの初期設定。位置はこのあと FirstPersonControls（タッチでは TouchControls）が目の高さに置く */
const CAMERA = { ...HOME_STAGE.camera, position: HOME_STAGE.spawn }
/** 描画の細かさの上限。重いときは PerformanceMonitor が 1 まで下げる */
const MAX_DPR = 1.5
/** 軽い表示（タッチの端末）での描画の細かさの上限 */
const LITE_MAX_DPR = 1.25
/** 軽い表示で照らす作品の数（PC は ArtworkSpotlights の既定の 6 つ） */
const LITE_ARTWORK_LIGHTS = 2
/** 軽い表示での太陽の影の細かさ（px。PC は lighting.tsx の既定の 2048） */
const LITE_SHADOW_MAP_SIZE = 1024
/** 軽い表示での映り込みの細かさ（立方体の 1 面の px。PC は lighting.tsx の既定の 128） */
const LITE_REFLECTION_SIZE = 64
/** renderer の設定。PC はふちのギザギザ取り（MSAA）を PostEffects の中でするので、Canvas では使わない */
const GL = { antialias: false, powerPreference: 'high-performance' } as const
/** 軽い表示は PostEffects を置かないので、Canvas のアンチエイリアスを使う */
const GL_LITE = { antialias: true, powerPreference: 'high-performance' } as const
/** 天井の板を部屋（内寸）より大きくする幅（m。両側で）。壁の中まで届かせる（隣の部屋の板とは壁の中で重なるが、同じ材質・同じ高さなので見えない） */
const CEILING_PAD = 0.6
/** 家の外形を読み込むまでの影の範囲の高さ（m） */
const SHADOW_TOP = 3.4
/** 縦長の画面で広げる視野角の上限（度） */
const MAX_PORTRAIT_FOV = 80
/** 縦長の画面で、横 / 縦が 1 から 1 減るごとに広げる視野角（度） */
const PORTRAIT_FOV_GAIN = 30

/** 縦長の画面（横 / 縦 < 1）では縦の視野角を base + (1 − 横 / 縦) × 30°（上限 80°）に広げる（横が狭くなりすぎないように。横長ではそのまま） */
function ResponsiveFov({ base }: { base: number }) {
  const camera = useThree((s) => s.camera)
  const size = useThree((s) => s.size)
  const invalidate = useThree((s) => s.invalidate)
  useLayoutEffect(() => {
    if (!(camera instanceof THREE.PerspectiveCamera) || size.width <= 0 || size.height <= 0) return
    const aspect = size.width / size.height
    camera.fov = Math.min(MAX_PORTRAIT_FOV, base + Math.max(0, 1 - aspect) * PORTRAIT_FOV_GAIN)
    camera.updateProjectionMatrix()
    invalidate()
  }, [camera, size.width, size.height, base, invalidate])
  return null
}

/**
 * 天井。家の GLB には天井が無いので、部屋ごとに壁の高さに板を張る。影は落とさない（太陽が天窓のように床を照らす）。
 * 名前は Ceiling で始める（当たり判定から外す。stagePreset の collisionIgnore）
 */
function Ceilings({ rooms }: { rooms: HouseRoom[] }) {
  const material = useMemo(() => new THREE.MeshStandardMaterial({ color: '#f4efe7', roughness: 0.95 }), [])
  useEffect(() => () => material.dispose(), [material])
  return (
    <>
      {rooms.map((room) => (
        <mesh
          key={room.id}
          name={`Ceiling_${room.id}`}
          position={[room.origin[0], CEILING_HEIGHT, room.origin[1]]}
          rotation-x={Math.PI / 2}
          material={material}
          castShadow={false}
          receiveShadow={false}
        >
          <planeGeometry args={[room.size[0] + CEILING_PAD, room.size[1] + CEILING_PAD]} />
        </mesh>
      ))}
    </>
  )
}

export function WalkScene({
  museum,
  paused = false,
  touch = false,
  walking: touchWalking = false,
  onStatus,
  onSelectArtwork,
  onStick,
}: {
  museum: Museum
  /** 作品カードを開いているときなど、操作を止めるときは true */
  paused?: boolean
  /**
   * タッチの端末か（画面が inputMode.ts の isTouchDevice で決める）。true なら操作を TouchControls にして、軽い表示（lite）にする。
   * Canvas の作り方が変わるので、表示している間は変えない
   */
  touch?: boolean
  /** タッチのとき、歩いているか（画面の「歩き始める」で true、「やめる」で false）。PC では使わない（クリックで歩き始める） */
  walking?: boolean
  onStatus?: (status: WalkStatus) => void
  /** 照準の先の作品を E / クリック（タッチでは右側のタップ）で選んだとき */
  onSelectArtwork?: (artworkId: string) => void
  /** タッチのとき、仮想スティックが出た・動いた・消えたとき（画面が DOM で描く。1 フレームに 1 回まで） */
  onStick?: (stick: TouchStick | null) => void
}) {
  const preset = HOME_STAGE
  const lite = touch
  const maxDpr = lite ? LITE_MAX_DPR : MAX_DPR
  // 作品の詳細画面から戻ったときは、前に立っていた場所から歩き続ける
  const player = useMemo(() => {
    const p = new Player(preset.player, preset.spawn, preset.lookAt)
    const pose = getWalkPose()
    if (pose) p.setPose(pose.feet, pose.yaw, pose.pitch)
    return p
  }, [preset])
  const materials = useMemo(() => createWalkMaterials(preset), [preset])
  const [bounds, setBounds] = useState<THREE.Box3 | null>(null)
  const [stageVersion, setStageVersion] = useState(0)
  /** PC：マウスが固定されているか（FirstPersonControls が知らせる） */
  const [pointerWalking, setPointerWalking] = useState(false)
  const [aimedArtworkId, setAimedArtworkId] = useState<string | null>(null)
  const [dpr, setDpr] = useState(() => Math.min(window.devicePixelRatio, maxDpr))
  /** 建物と家具をまとめたグループ（当たり判定・影の範囲・材質の調整の対象） */
  const stageRef = useRef<THREE.Group>(null)
  /** 描く建物（model_url のある部屋。リビングは walk_model_url があればそれ） */
  const shells = useShells(museum, true)
  /** 読み込んだ建物の部屋 */
  const loadedRooms = useRef(new Set<RoomId>())
  /**
   * 建物が全部そろったか（床が無いうちに当たり判定を作ると、落ちてしまうため）。
   * 1 部屋でもそろっていなければ当たり判定を作らない（ready にならない）
   */
  const shellLoaded = useRef(false)
  const shellsRef = useRef(shells)
  shellsRef.current = shells
  const rebuildFrame = useRef(0)

  // 部屋の位置と大きさ（3 秒ごとの取り直しで配列は新しくなるので、値が変わったときだけ作り直す）
  const rooms = houseRoomsOf(museum)
  const wall = wallThicknessOf(museum)
  const roomsKey = rooms.map((r) => `${r.id}:${r.origin.join(',')}:${r.size.join(',')}`).join('|') + `:${wall}`
  const { spotLights, initialBounds } = useMemo(() => {
    const b = houseBounds(rooms, wall)
    return {
      spotLights: roomDownlights(preset.roomLights, rooms, lite),
      initialBounds: new THREE.Box3(new THREE.Vector3(b.minX, 0, b.minZ), new THREE.Vector3(b.maxX, SHADOW_TOP, b.maxZ)),
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [roomsKey, preset, lite])

  // 当たり判定・影の範囲・影と映り込みを作り直す。続けて呼ばれても 1 回にまとめる（0.03 秒ほどで終わる）。
  // requestAnimationFrame だとタブが裏にあるとき止まり、「読み込み中」のままになるので setTimeout を使う
  const rebuild = useCallback(() => {
    if (rebuildFrame.current) return
    rebuildFrame.current = window.setTimeout(() => {
      rebuildFrame.current = 0
      const root = stageRef.current
      if (!root || !shellLoaded.current) return
      materials.apply(root)
      player.setWorld(buildCollisionWorld(root, preset.collisionIgnore))
      setBounds(new THREE.Box3().setFromObject(root))
      setStageVersion((v) => v + 1)
    }, 0)
  }, [materials, player, preset])

  // 建物（1 部屋分）を読み込んだとき。材質はすぐに整え（整える前の見た目が一瞬出ないように）、
  // 全部の部屋がそろっていれば、当たり判定は次のフレームで作る
  const onStageLoaded = useCallback(
    (root: THREE.Object3D, roomId: RoomId) => {
      materials.apply(root)
      loadedRooms.current.add(roomId)
      shellLoaded.current = shellsRef.current.every((s) => loadedRooms.current.has(s.room.id))
      if (shellLoaded.current) rebuild()
    },
    [materials, rebuild],
  )

  useEffect(
    () => () => {
      clearTimeout(rebuildFrame.current)
      rebuildFrame.current = 0
      materials.dispose()
      player.setWorld(null)
      // 次に開いたとき（作品の詳細画面から戻ったときなど）に、同じ場所から歩き続けられるよう覚えておく
      const feet = player.feet(new THREE.Vector3())
      saveWalkPose({ feet: [feet.x, feet.y, feet.z], yaw: player.yaw, pitch: player.pitch })
    },
    [materials, player],
  )

  const ready = stageVersion > 0
  // 歩いているか。タッチは画面の指示どおり（作品カードを開いている間は止まり、閉じたらそのまま続ける）
  const walking = touch ? ready && touchWalking && !paused : pointerWalking
  useEffect(() => {
    onStatus?.({ phase: ready ? 'ready' : 'loading', walking, aimedArtworkId })
  }, [onStatus, ready, walking, aimedArtworkId])

  const onInteract = useCallback(() => {
    if (aimedArtworkId) onSelectArtwork?.(aimedArtworkId)
  }, [aimedArtworkId, onSelectArtwork])

  if (shells.length === 0) return null

  return (
    <Canvas
      dpr={dpr}
      // 歩いていないときは、変化があったときだけ描く
      frameloop={walking ? 'always' : 'demand'}
      shadows={SHADOWS}
      camera={CAMERA}
      // ふちのギザギザ取り：PC は PostEffects の中の MSAA、軽い表示は Canvas の antialias
      gl={lite ? GL_LITE : GL}
      onCreated={({ gl }) => {
        // 白い壁や子どもの作品の色がくすまず、明るいところだけなめらかに抑えるトーンマッピングと、sRGB への変換。
        // PC は PostEffects の最後（OutputPass）が、軽い表示は描くときに renderer がそのまま、この設定を使う（どちらも同じ色になる）
        gl.toneMapping = THREE.NeutralToneMapping
        gl.toneMappingExposure = 1
        gl.outputColorSpace = THREE.SRGBColorSpace
      }}
    >
      <PerformanceMonitor onDecline={() => setDpr(1)} onIncline={() => setDpr(Math.min(window.devicePixelRatio, maxDpr))} />
      <ResponsiveFov base={preset.camera.fov} />
      <MuseumDaylight
        preset={preset}
        bounds={bounds}
        initialBounds={initialBounds}
        spotLights={spotLights}
        shadowMapSize={lite ? LITE_SHADOW_MAP_SIZE : undefined}
      />
      <group ref={stageRef}>
        {/* 建物（部屋ごと）と家具・作品。当たり判定はこのグループ全体から作る */}
        <HouseShells museum={museum} walk onLoaded={onStageLoaded} />
        <HomeObjects layout={museum.layout} catalog={museum.catalog} slots={museum.slots} house={museum.house} onReady={rebuild} />
      </group>
      <Ceilings rooms={rooms} />
      <ArtworkSpotlights slots={museum.slots} player={player} maxLights={lite ? LITE_ARTWORK_LIGHTS : undefined} />
      <SharpTextures />
      <StaticShadows version={stageVersion} />
      <ReflectionCapture
        position={preset.reflection.position}
        intensity={preset.reflection.intensity}
        version={stageVersion}
        size={lite ? LITE_REFLECTION_SIZE : undefined}
      />
      {touch ? (
        <TouchControls
          player={player}
          active={ready}
          walking={touchWalking}
          suspended={paused}
          onInteract={onInteract}
          onStick={onStick}
        />
      ) : (
        <FirstPersonControls
          player={player}
          active={ready}
          suspended={paused}
          onWalkingChange={setPointerWalking}
          onInteract={onInteract}
        />
      )}
      <ArtworkPicker active={ready && walking} onAim={setAimedArtworkId} />
      {!lite && <PostEffects />}
    </Canvas>
  )
}
