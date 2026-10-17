// 一人称の操作（PC）。タッチの端末では、代わりに TouchControls.tsx を使う（WalkScene が選ぶ）。
//   クリック … マウスを画面に固定して歩き始める（Pointer Lock）
//   W A S D / 矢印キー … 前後左右に歩く　　Shift … 速く歩く　　マウス … 見回す
//   Esc … マウスの固定を外して止まる
//   E / クリック（歩いているとき）… 照準の先の作品を見る（onInteract）
// Pointer Lock が使えないとき（ブラウザの設定など）は、ドラッグで見回す。
//
// 入力を読んで player.ts の Player を動かし、カメラを目の位置に置くだけ（カメラの置き方は TouchControls と共通の playerCamera.ts）。
// 動きや当たり判定は player.ts、ステージの読み込みは WalkScene.tsx が担当する。

import { useCallback, useEffect, useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import type { MoveInput, Player } from './player'
import { settleOnFloor, syncCameraToPlayer } from './playerCamera'

const FORWARD_KEYS = ['KeyW', 'ArrowUp']
const BACK_KEYS = ['KeyS', 'ArrowDown']
const LEFT_KEYS = ['KeyA', 'ArrowLeft']
const RIGHT_KEYS = ['KeyD', 'ArrowRight']
const RUN_KEYS = ['ShiftLeft', 'ShiftRight']
const HANDLED_KEYS = new Set([...FORWARD_KEYS, ...BACK_KEYS, ...LEFT_KEYS, ...RIGHT_KEYS, ...RUN_KEYS])

/** マウスを固定した直後などに、ブラウザがまれに返す極端な移動量は無視する */
const MAX_MOUSE_DELTA = 400

export function FirstPersonControls({
  player,
  active,
  suspended = false,
  onWalkingChange,
  onInteract,
}: {
  player: Player
  /** ステージと当たり判定の準備ができたら true。false の間は操作を受け付けない */
  active: boolean
  /** 作品カードを開いているときなど、いったん止めるときは true（マウスの固定も外す） */
  suspended?: boolean
  /** 歩いている（操作を受け付けている）かが変わったとき */
  onWalkingChange?: (walking: boolean) => void
  /** 歩いているときに E を押したか、クリックしたとき（照準の先の作品を見る） */
  onInteract?: () => void
}) {
  const camera = useThree((s) => s.camera)
  const canvas = useThree((s) => s.gl.domElement)
  const invalidate = useThree((s) => s.invalidate)
  const keys = useRef(new Set<string>())
  const walking = useRef(false)
  const input = useRef<MoveInput>({ forward: 0, right: 0, run: false })
  // イベントの登録をやり直さずに最新の値を読むため、ref に入れておく
  const interact = useRef(onInteract)
  const isSuspended = useRef(suspended)
  const stopWalking = useRef<() => void>(() => {})
  useLayoutEffect(() => {
    interact.current = onInteract
    isSuspended.current = suspended
  })

  const syncCamera = useCallback(() => syncCameraToPlayer(camera, player), [player, camera])

  // 準備ができたら、床に足をつけた状態でカメラを置く
  useLayoutEffect(() => {
    if (!active) return
    settleOnFloor(player)
    syncCamera()
    invalidate()
  }, [active, player, syncCamera, invalidate])

  useEffect(() => {
    if (!active) return
    let dragging = false

    const setWalking = (next: boolean) => {
      if (walking.current === next) return
      walking.current = next
      if (!next) keys.current.clear()
      onWalkingChange?.(next)
      invalidate()
    }
    const look = (dx: number, dy: number) => {
      if (Math.abs(dx) > MAX_MOUSE_DELTA || Math.abs(dy) > MAX_MOUSE_DELTA) return
      player.look(dx, dy)
      syncCamera()
      invalidate()
    }
    const isLocked = () => document.pointerLockElement === canvas
    stopWalking.current = () => {
      if (isLocked()) document.exitPointerLock()
      else setWalking(false)
    }

    const onPointerDown = (e: PointerEvent) => {
      if (e.button !== 0 || isSuspended.current) return
      if (walking.current && isLocked()) {
        interact.current?.()
        return
      }
      if (!walking.current) {
        // 固定できなかったときは pointerlockerror が来て、ドラッグで見回す方式になる
        try {
          const request = canvas.requestPointerLock() as unknown as Promise<void> | undefined
          request?.catch?.(() => setWalking(true))
        } catch {
          setWalking(true)
        }
      }
      if (!isLocked()) dragging = true
    }
    const onPointerUp = () => {
      dragging = false
    }
    const onMouseMove = (e: MouseEvent) => {
      if (isLocked() || (dragging && walking.current)) look(e.movementX, e.movementY)
    }
    const onLockChange = () => setWalking(isLocked())
    const onLockError = () => setWalking(true)

    const onKeyDown = (e: KeyboardEvent) => {
      if (!walking.current) return
      if (e.code === 'Escape' && !isLocked()) {
        setWalking(false)
        return
      }
      if (e.code === 'KeyE') {
        e.preventDefault()
        interact.current?.()
        return
      }
      if (!HANDLED_KEYS.has(e.code)) return
      e.preventDefault()
      keys.current.add(e.code)
    }
    const onKeyUp = (e: KeyboardEvent) => {
      keys.current.delete(e.code)
    }
    // 別のウィンドウに移ったときに、キーが押されたままにならないようにする
    const onBlur = () => keys.current.clear()

    canvas.addEventListener('pointerdown', onPointerDown)
    window.addEventListener('pointerup', onPointerUp)
    window.addEventListener('mousemove', onMouseMove)
    document.addEventListener('pointerlockchange', onLockChange)
    document.addEventListener('pointerlockerror', onLockError)
    window.addEventListener('keydown', onKeyDown)
    window.addEventListener('keyup', onKeyUp)
    window.addEventListener('blur', onBlur)
    return () => {
      canvas.removeEventListener('pointerdown', onPointerDown)
      window.removeEventListener('pointerup', onPointerUp)
      window.removeEventListener('mousemove', onMouseMove)
      document.removeEventListener('pointerlockchange', onLockChange)
      document.removeEventListener('pointerlockerror', onLockError)
      window.removeEventListener('keydown', onKeyDown)
      window.removeEventListener('keyup', onKeyUp)
      window.removeEventListener('blur', onBlur)
      if (isLocked()) document.exitPointerLock()
      keys.current.clear()
      walking.current = false
    }
  }, [active, canvas, player, syncCamera, invalidate, onWalkingChange])

  // 止めるように言われたら、マウスの固定を外して止まる
  useEffect(() => {
    if (suspended) stopWalking.current()
  }, [suspended])

  useFrame((_, delta) => {
    if (!active) return
    const pressed = (codes: string[]) => codes.some((c) => keys.current.has(c))
    const move = input.current
    move.forward = (pressed(FORWARD_KEYS) ? 1 : 0) - (pressed(BACK_KEYS) ? 1 : 0)
    move.right = (pressed(RIGHT_KEYS) ? 1 : 0) - (pressed(LEFT_KEYS) ? 1 : 0)
    move.run = pressed(RUN_KEYS)
    player.update(delta, move)
    syncCamera()
  })

  return null
}
