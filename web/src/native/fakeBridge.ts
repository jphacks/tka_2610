// 開発のときだけ使う偽の橋渡し（bridge.ts から import.meta.env.DEV のときだけ呼ばれ、本番のビルドには入らない）。
// URL に ?fakeNative=1 を付けて開くと、アプリの中と同じように「3D 生成で追加」が出て、撮影は少し待ってから絵を描いた JPEG を返す。
//   ?fakeNative=1        ふつう（撮影が終わる）
//   ?fakeNative=cancel   撮影画面で「やめる」を押した返事
//   ?fakeNative=pending  渡しそびれた結果が 1 つある（作品を追加の画面を開くと、フォームに入る）
//   ?fakeNative=error    アプリがエラーを返す
//   ?fakeNative=0        やめる
// 付けた値はこのタブの sessionStorage に覚えるので、画面を移っても（マイページなど）続く。
import type { BridgeTransport } from './bridge'

type FakeMode = 'ok' | 'cancel' | 'pending' | 'error'

const STORAGE_KEY = 'memoria.fakeNative'

const INFO = {
  capture: true,
  version: 1,
  sheets: [
    { id: 'yatsugiri', label: '八つ切（27.1 × 39.2 cm）' },
    { id: 'yotsugiri', label: '四つ切（39.2 × 54.2 cm）' },
    { id: 'a4', label: 'A4（21.0 × 29.7 cm）' },
    { id: 'b4', label: 'B4（25.7 × 36.4 cm）' },
  ],
  heightCm: { min: 0.5, max: 300 },
}

function modeOf(value: string | null): FakeMode | null {
  if (value === null || value === '' || value === '0' || value === 'off') return null
  if (value === 'cancel' || value === 'pending' || value === 'error') return value
  return 'ok'
}

function currentMode(): FakeMode | null {
  const param = new URLSearchParams(window.location.search).get('fakeNative')
  try {
    if (param !== null) {
      if (modeOf(param)) sessionStorage.setItem(STORAGE_KEY, param)
      else sessionStorage.removeItem(STORAGE_KEY)
      return modeOf(param)
    }
    return modeOf(sessionStorage.getItem(STORAGE_KEY))
  } catch {
    return modeOf(param)
  }
}

let sessionCount = 0
let pendingUsed = false

/** 撮った写真の代わりに、canvas に描いた JPEG（base64） */
function drawPhoto(kind: 'object' | 'flat'): string {
  const canvas = document.createElement('canvas')
  canvas.width = kind === 'flat' ? 900 : 1200
  canvas.height = kind === 'flat' ? 1200 : 900
  const g = canvas.getContext('2d')!
  const { width: w, height: h } = canvas
  g.fillStyle = kind === 'flat' ? '#fbf6ec' : '#d9d2c5'
  g.fillRect(0, 0, w, h)
  if (kind === 'flat') {
    // 画用紙に描いた虹とお日さま
    const colors = ['#e2574c', '#f0a23b', '#f4d03f', '#5fb36b', '#4a90c9', '#7d5ba6']
    g.lineWidth = 34
    colors.forEach((c, i) => {
      g.strokeStyle = c
      g.beginPath()
      g.arc(w / 2, h * 0.62, w * 0.36 - i * 36, Math.PI, 0)
      g.stroke()
    })
    g.fillStyle = '#f4b942'
    g.beginPath()
    g.arc(w * 0.78, h * 0.18, 70, 0, Math.PI * 2)
    g.fill()
  } else {
    // 机の上の箱の工作
    g.fillStyle = '#c98b5a'
    g.fillRect(w * 0.36, h * 0.38, w * 0.28, h * 0.36)
    g.fillStyle = '#e0a878'
    g.beginPath()
    g.moveTo(w * 0.36, h * 0.38)
    g.lineTo(w * 0.44, h * 0.28)
    g.lineTo(w * 0.72, h * 0.28)
    g.lineTo(w * 0.64, h * 0.38)
    g.closePath()
    g.fill()
    g.fillStyle = '#4a90c9'
    g.beginPath()
    g.arc(w * 0.5, h * 0.55, 40, 0, Math.PI * 2)
    g.fill()
  }
  g.fillStyle = 'rgba(0, 0, 0, 0.45)'
  g.font = 'bold 36px sans-serif'
  g.fillText(`fakeNative ${kind}`, 28, h - 32)
  return canvas.toDataURL('image/jpeg', 0.85).replace(/^data:[^,]*,/, '')
}

function result(kind: 'object' | 'flat') {
  sessionCount += 1
  const sessionId = `fake-${kind}-${sessionCount}`
  return { kind, sessionId, photoCount: kind === 'flat' ? 1 : 24, mime: 'image/jpeg', image: drawPhoto(kind) }
}

const wait = (ms: number) => new Promise((resolve) => window.setTimeout(resolve, ms))

/** 偽の橋渡し。?fakeNative が無ければ null */
export function fakeBridge(): { info: unknown; post: BridgeTransport } | null {
  const mode = currentMode()
  if (!mode) return null
  const post: BridgeTransport = async (message) => {
    console.info('[fakeNative]', message.type, message)
    if (mode === 'error') {
      await wait(300)
      throw new Error('（偽の橋渡し）撮影の画面を開けませんでした')
    }
    switch (message.type) {
      case 'startCapture': {
        await wait(1200)
        if (mode === 'cancel') return { cancelled: true }
        return result(message.kind === 'flat' ? 'flat' : 'object')
      }
      case 'pendingCapture': {
        await wait(150)
        if (mode !== 'pending' || pendingUsed) return null
        pendingUsed = true
        return result('flat')
      }
      case 'artworkCreated':
      case 'openSessions':
        return null
      default:
        throw new Error(`unknown message: ${message.type}`)
    }
  }
  return { info: INFO, post }
}
