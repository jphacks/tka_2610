// 飾っている作品を照らすスポットライト（美術館の作品用の照明のようなもの）。
// 作品のほぼ真上（少しだけ手前）から、作品に向けて光を当てる。本棚の段の作品は、上の棚板にさえぎられないよう低く遠くから当てる。
// 作品の置き場所と向きは /api/museum の slots（世界座標の面の中心・yaw・作品を収める枠）を使う。
// 作品は十数点あり、全部に照明を付けるとライトが多すぎて重くなるので、
// 歩いている人に近い作品から LIGHT_COUNT 個（スマホなどの軽い表示では maxLights で渡す数）だけ照らし、歩くのに合わせて付け替える。
// ライトの数は、飾っている作品の数（か maxLights）が変わったときだけ変える（数が変わるとシェーダーを作り直すため）。

import { useEffect, useMemo, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import * as THREE from 'three'
import type { SlotView } from '../../../api'
import type { Player } from './player'

const LIGHT_COUNT = 6
/** 作品の正面から手前・上へずらした位置にライトを置く（m） */
const LIGHT_FORWARD = 0.6
const LIGHT_UP = 1.7
/** 作品の中心くらいの高さを狙う（天板や床からの高さ, m）。枠が低い作品は枠の高さの半分 */
const AIM_UP = 0.45
/**
 * 棚の段の作品は、狙う点より SHELF_LIGHT_UP 上・SHELF_LIGHT_FORWARD 手前から当てる（m）。
 * 段の手前の縁（作品から約 0.2 m）を通る光の高さが「狙う点 + 0.1 m」になり、上の棚板（すき間 0.38〜0.40 m）の下を通る
 */
const SHELF_LIGHT_FORWARD = 1.2
const SHELF_LIGHT_UP = 0.6
/** 枠の高さがこれより低い作品は棚の段にある（Rust の art_fit：棚の段では「すき間 − 4 cm」で 0.62 m より低くなる） */
const SHELF_FIT_HEIGHT = 0.6
/** 照明を置く高さの上限（天井 3.2 m より下。本棚の天板の作品で天井を突き抜けないように） */
const LIGHT_MAX_Y = 3.0
/** 作品の照明の明るさ（three.js の単位）と色（少し暖かい白） */
const INTENSITY = 6
const COLOR = new THREE.Color().setRGB(1, 0.94, 0.86, THREE.SRGBColorSpace)
/** 何回に 1 回、近い作品を選び直すか（毎フレームでなくてよい） */
const RESELECT_EVERY_FRAMES = 15

interface Target {
  light: [number, number, number]
  aim: [number, number, number]
}

/** 作品の置き場所と向き（yaw）と枠から、照明の位置と狙う点を決める */
function targetOf(slot: SlotView): Target {
  const [x, y, z] = slot.position
  const yaw = THREE.MathUtils.degToRad(slot.yaw)
  // 作品の正面は +Z を yaw だけ回した向き
  const fx = Math.sin(yaw)
  const fz = Math.cos(yaw)
  const aimY = y + Math.min(AIM_UP, slot.fit[1] / 2)
  const onShelf = slot.parent_id !== null && slot.fit[1] < SHELF_FIT_HEIGHT
  const forward = onShelf ? SHELF_LIGHT_FORWARD : LIGHT_FORWARD
  const lightY = Math.min(onShelf ? aimY + SHELF_LIGHT_UP : y + LIGHT_UP, LIGHT_MAX_Y)
  return {
    light: [x + fx * forward, lightY, z + fz * forward],
    aim: [x, aimY, z],
  }
}

export function ArtworkSpotlights({
  slots,
  player,
  maxLights = LIGHT_COUNT,
}: {
  slots: SlotView[]
  player: Player
  /** 照らす作品の数の上限（スマホなどの軽い表示では少なくする） */
  maxLights?: number
}) {
  const targets = useMemo(() => slots.filter((s) => s.artwork).map((s) => ({ ...targetOf(s), position: s.position })), [slots])

  const count = Math.min(maxLights, targets.length)
  const lights = useMemo(
    () => Array.from({ length: count }, () => new THREE.SpotLight(COLOR, 0, 4, THREE.MathUtils.degToRad(30), 0.6, 2)),
    [count],
  )
  useEffect(() => () => lights.forEach((l) => l.dispose()), [lights])

  const frame = useRef(0)
  const invalidate = useThree((s) => s.invalidate)
  // ライトを作り直したら、次のフレームですぐに照らす作品を選ぶ
  useEffect(() => {
    frame.current = 0
    invalidate()
  }, [lights, targets, invalidate])
  const feet = useMemo(() => new THREE.Vector3(), [])

  useFrame(() => {
    if (frame.current++ % RESELECT_EVERY_FRAMES !== 0) return
    player.feet(feet)
    const nearest = targets
      .map((t) => ({ t, d: (t.position[0] - feet.x) ** 2 + (t.position[1] - feet.y) ** 2 + (t.position[2] - feet.z) ** 2 }))
      .sort((a, b) => a.d - b.d)
      .slice(0, lights.length)
    lights.forEach((light, i) => {
      const target = nearest[i].t
      light.intensity = INTENSITY
      light.position.set(...target.light)
      light.target.position.set(...target.aim)
      light.target.updateMatrixWorld()
    })
  })

  return (
    <>
      {lights.map((light, i) => (
        <primitive key={i} object={light} />
      ))}
    </>
  )
}
