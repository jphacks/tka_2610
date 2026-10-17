// タッチの端末（スマホ・タブレット）の一人称の操作。WalkScene が、PC の FirstPersonControls の代わりに置く。
//   画面の左 45%（STICK_AREA）… 指を置いた所に仮想スティックが出て、指を引いた向きに歩く。
//                                半径の 10% までは止まったまま（DEAD_ZONE）、90% より先まで引くと速く歩く（RUN_AT）。離すと止まる
//   画面の右 55% … 1 本の指でなぞって見回す（1 px なぞるごとに横は 0.3°、縦は 0.22°。画面の大きさによらない）。
//                   軽くタップする（動きが 10px 未満・300 ms 未満）と、照準の先の作品を見る（onInteract）
// 指は pointerId で見分けるので、左の指で歩きながら右の指で見回せる（左右 1 本ずつ。それより多い指は無視する）。
// Pointer Lock は使わない。歩き始める・やめるは画面が決めて walking で渡す（画面の「歩き始める」と「やめる」）。
// スティックの見た目は画面（pages/MuseumWalk.tsx）が DOM で描く。ここからは onStick で中心とつまみの位置を知らせる
// （変わったときだけ、1 フレームに 1 回まで。指を離したら null）。
// キャンバスには touch-action: none を付けて、なぞってもページがスクロール・拡大しないようにする。
// マウスでも同じように動くので、PC でも ?input=touch を付けて試せる（inputMode.ts）。
//
// 入力を読んで player.ts の Player を動かし、カメラを目の位置に置くだけ（FirstPersonControls と同じ。カメラの置き方は playerCamera.ts）。

import { useCallback, useEffect, useLayoutEffect, useRef } from 'react'
import { useFrame, useThree } from '@react-three/fiber'
import { TOUCH_STICK_RADIUS, type TouchStick } from './inputMode'
import type { MoveInput, Player } from './player'
import { settleOnFloor, syncCameraToPlayer } from './playerCamera'

/** 歩くための指を受け付ける範囲（キャンバスの左からの割合）。残りは見回す範囲 */
const STICK_AREA = 0.45
/** スティックの中心からこの割合（半径に対して）までは止まったまま（指のふるえで歩き出さないように） */
const DEAD_ZONE = 0.1
/** スティックをこの割合より先まで引くと、速く歩く（PC の Shift と同じ） */
const RUN_AT = 0.9
/**
 * 横になぞったとき、1 px（CSS の px）あたりに回る角度（度）。キャンバスの大きさによらない
 * （横幅で割ると、縦長のスマホでは少しなぞっただけで大きく回ってしまうため。横幅 390 px なら約 117°）
 */
const TOUCH_TURN_DEG_PER_PX = 0.3
/** 縦になぞったとき、1 px あたりに上下を向く角度（度）。横より小さくして、見上げ・見下ろしすぎないようにする（150 px で約 33°） */
const TOUCH_PITCH_DEG_PER_PX = 0.22
/** 1 回のイベントでこれより大きく動いた（px）ときは、取りこぼしなどの異常な値として無視する（PC の MAX_MOUSE_DELTA と同じ考え方） */
const MAX_TOUCH_DELTA = 160
/** これより動かず（px）、これより短い時間（ミリ秒）で離したら、タップとみなす */
const TAP_MAX_MOVE = 10
const TAP_MAX_MS = 300

/** 歩くための指（仮想スティック） */
interface StickFinger {
  id: number
  /** 指を置いた所（画面の座標。動かした量を測る） */
  startX: number
  startY: number
  /** 指を置いた所（キャンバスの左上から。画面に知らせる） */
  x: number
  y: number
  /** 中心からつまみまで（半径 TOUCH_STICK_RADIUS までに収める） */
  dx: number
  dy: number
}

/** 見回すための指 */
interface LookFinger {
  id: number
  /** 前のイベントの位置（画面の座標） */
  lastX: number
  lastY: number
  /** 指を置いた所と時刻（タップかどうかを見分ける） */
  startX: number
  startY: number
  startTime: number
  /** タップとみなせないほど動いたか */
  moved: boolean
}

export function TouchControls({
  player,
  active,
  walking,
  suspended = false,
  onInteract,
  onStick,
}: {
  player: Player
  /** ステージと当たり判定の準備ができたら true。false の間は操作を受け付けない */
  active: boolean
  /** 歩いているか（画面の「歩き始める」で true、「やめる」で false）。false の間は指の操作を受け付けない */
  walking: boolean
  /** 作品カードを開いているときなど、いったん止めるときは true（指の入力を捨て、スティックを消す） */
  suspended?: boolean
  /** 右側を軽くタップしたとき（照準の先の作品を見る） */
  onInteract?: () => void
  /** 仮想スティックが出た・動いた・消えたとき（画面が描く） */
  onStick?: (stick: TouchStick | null) => void
}) {
  const camera = useThree((s) => s.camera)
  const canvas = useThree((s) => s.gl.domElement)
  const invalidate = useThree((s) => s.invalidate)
  const stick = useRef<StickFinger | null>(null)
  const look = useRef<LookFinger | null>(null)
  const input = useRef<MoveInput>({ forward: 0, right: 0, run: false })
  /** 最後に画面に知らせたスティック（変わっていなければ知らせ直さない） */
  const reported = useRef<TouchStick | null>(null)
  // イベントの登録をやり直さずに最新の値を読むため、ref に入れておく
  const interact = useRef(onInteract)
  const stickChanged = useRef(onStick)
  useLayoutEffect(() => {
    interact.current = onInteract
    stickChanged.current = onStick
  })
  const enabled = active && walking && !suspended

  /** スティックが前に知らせたときから変わっていたら、画面に知らせる */
  const flushStick = useCallback(() => {
    const s = stick.current
    const last = reported.current
    if (!s) {
      if (last) {
        reported.current = null
        stickChanged.current?.(null)
      }
      return
    }
    if (last && last.x === s.x && last.y === s.y && last.dx === s.dx && last.dy === s.dy) return
    const next = { x: s.x, y: s.y, dx: s.dx, dy: s.dy }
    reported.current = next
    stickChanged.current?.(next)
  }, [])

  // 準備ができたら、床に足をつけた状態でカメラを置く
  useLayoutEffect(() => {
    if (!active) return
    settleOnFloor(player)
    syncCameraToPlayer(camera, player)
    invalidate()
  }, [active, player, camera, invalidate])

  // なぞってもページがスクロール・拡大しないようにする
  useEffect(() => {
    const previous = canvas.style.touchAction
    canvas.style.touchAction = 'none'
    return () => {
      canvas.style.touchAction = previous
    }
  }, [canvas])

  useEffect(() => {
    if (!enabled) return

    const onPointerDown = (e: PointerEvent) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return
      const rect = canvas.getBoundingClientRect()
      const x = e.clientX - rect.left
      const y = e.clientY - rect.top
      if (x < rect.width * STICK_AREA) {
        if (stick.current) return
        stick.current = { id: e.pointerId, startX: e.clientX, startY: e.clientY, x, y, dx: 0, dy: 0 }
      } else {
        if (look.current) return
        look.current = {
          id: e.pointerId,
          lastX: e.clientX,
          lastY: e.clientY,
          startX: e.clientX,
          startY: e.clientY,
          startTime: performance.now(),
          moved: false,
        }
      }
      // 指がキャンバスの外（ボタンの上など）へ出ても、離すまでこのキャンバスに届くようにする
      try {
        canvas.setPointerCapture(e.pointerId)
      } catch {
        // 取れなくても、動きと離したことは window で受け取る
      }
      // 長押しで文字の選択や拡大鏡が出ないようにする
      e.preventDefault()
    }

    const onPointerMove = (e: PointerEvent) => {
      const s = stick.current
      if (s && s.id === e.pointerId) {
        let dx = e.clientX - s.startX
        let dy = e.clientY - s.startY
        const length = Math.hypot(dx, dy)
        if (length > TOUCH_STICK_RADIUS) {
          dx *= TOUCH_STICK_RADIUS / length
          dy *= TOUCH_STICK_RADIUS / length
        }
        s.dx = dx
        s.dy = dy
        return
      }
      const l = look.current
      if (!l || l.id !== e.pointerId) return
      const dx = e.clientX - l.lastX
      const dy = e.clientY - l.lastY
      l.lastX = e.clientX
      l.lastY = e.clientY
      if (Math.hypot(e.clientX - l.startX, e.clientY - l.startY) >= TAP_MAX_MOVE) l.moved = true
      if (Math.abs(dx) > MAX_TOUCH_DELTA || Math.abs(dy) > MAX_TOUCH_DELTA) return
      // player.look は渡した値 1 につき lookDegPerPixel 度回すので、1 px あたり TOUCH_TURN_DEG_PER_PX・TOUCH_PITCH_DEG_PER_PX 度になるよう割り直す
      // （上下の限度 pitchLimitDeg は player.look の中でそのまま効く）
      const unit = player.spec.lookDegPerPixel
      player.look((dx * TOUCH_TURN_DEG_PER_PX) / unit, (dy * TOUCH_PITCH_DEG_PER_PX) / unit)
      syncCameraToPlayer(camera, player)
      invalidate()
    }

    const onPointerEnd = (e: PointerEvent) => {
      if (stick.current?.id === e.pointerId) stick.current = null
      const l = look.current
      if (!l || l.id !== e.pointerId) return
      look.current = null
      const tapped =
        e.type === 'pointerup' &&
        !l.moved &&
        Math.hypot(e.clientX - l.startX, e.clientY - l.startY) < TAP_MAX_MOVE &&
        performance.now() - l.startTime < TAP_MAX_MS
      if (tapped) interact.current?.()
    }

    // 別のアプリに切り替えたときなどに、指を置いたままにならないようにする
    const release = () => {
      stick.current = null
      look.current = null
    }
    // 長押しでメニューが出ないようにする
    const onContextMenu = (e: Event) => e.preventDefault()

    canvas.addEventListener('pointerdown', onPointerDown)
    canvas.addEventListener('contextmenu', onContextMenu)
    window.addEventListener('pointermove', onPointerMove)
    window.addEventListener('pointerup', onPointerEnd)
    window.addEventListener('pointercancel', onPointerEnd)
    window.addEventListener('blur', release)
    return () => {
      canvas.removeEventListener('pointerdown', onPointerDown)
      canvas.removeEventListener('contextmenu', onContextMenu)
      window.removeEventListener('pointermove', onPointerMove)
      window.removeEventListener('pointerup', onPointerEnd)
      window.removeEventListener('pointercancel', onPointerEnd)
      window.removeEventListener('blur', release)
      release()
      // 止めたあとは描き直し（useFrame）も止まるので、スティックを消したことはここで知らせる
      flushStick()
    }
  }, [enabled, canvas, camera, player, invalidate, flushStick])

  useFrame((_, delta) => {
    if (!active) return
    const move = input.current
    const s = stick.current
    const length = s ? Math.hypot(s.dx, s.dy) / TOUCH_STICK_RADIUS : 0
    if (s && length > DEAD_ZONE) {
      // 止まったままの範囲の外側を 0〜1 に引き直す（引き始めから、なめらかに速くなる）。前は画面の上向き
      const scale = (length - DEAD_ZONE) / (1 - DEAD_ZONE) / (length * TOUCH_STICK_RADIUS)
      move.right = s.dx * scale
      move.forward = -s.dy * scale
      move.run = length >= RUN_AT
    } else {
      move.forward = 0
      move.right = 0
      move.run = false
    }
    player.update(delta, move)
    syncCameraToPlayer(camera, player)
    flushStick()
  })

  return null
}
