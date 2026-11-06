// PC で見たときに、アプリの枠をスマホ端末のように見せる飾り（横のボタン・ダイナミックアイランド・時刻と電波と電池・ホームバー）。
// 見た目だけで、押せない（pointer-events: none）。スマホでは CSS で隠す（本物の時刻とノッチがあるため）。
// 黒いふちと金属のふちは App.css の .device が描く。画面の上下の余白は、PC の枠のときだけ --safe-top・--safe-bottom に入れる（App.css）。
import { useEffect, useState } from 'react'
import './DeviceFrame.css'

function nowLabel() {
  const d = new Date()
  return `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`
}

/** 時刻（分が変わったときだけ描き直す） */
function useClock() {
  const [label, setLabel] = useState(nowLabel)
  useEffect(() => {
    let timer = 0
    const tick = () => {
      setLabel(nowLabel())
      timer = window.setTimeout(tick, 60_000 - (Date.now() % 60_000) + 50)
    }
    timer = window.setTimeout(tick, 60_000 - (Date.now() % 60_000) + 50)
    return () => window.clearTimeout(timer)
  }, [])
  return label
}

export function DeviceFrame() {
  const time = useClock()
  return (
    <div className="device-chrome" aria-hidden="true">
      {/* 横のボタン（左：アクションボタン・音量の上下、右：電源） */}
      <span className="device-btn is-action" />
      <span className="device-btn is-volume-up" />
      <span className="device-btn is-volume-down" />
      <span className="device-btn is-power" />

      <div className="device-status">
        <span className="device-time">{time}</span>
        <span className="device-icons">
          {/* 電波 */}
          <svg width="18" height="12" viewBox="0 0 18 12" fill="currentColor">
            <rect x="0" y="7.5" width="3.2" height="4.5" rx="1" />
            <rect x="4.9" y="5.2" width="3.2" height="6.8" rx="1" />
            <rect x="9.8" y="2.6" width="3.2" height="9.4" rx="1" />
            <rect x="14.7" y="0" width="3.2" height="12" rx="1" />
          </svg>
          {/* Wi-Fi */}
          <svg width="16" height="12" viewBox="0 0 16 12" fill="none" stroke="currentColor" strokeWidth="1.9" strokeLinecap="round">
            <path d="M1.64 4.14A9 9 0 0 1 14.36 4.14" />
            <path d="M4.18 6.88A5.4 5.4 0 0 1 11.82 6.88" />
            <circle cx="8" cy="10.2" r="1.6" fill="currentColor" stroke="none" />
          </svg>
          {/* 電池 */}
          <svg width="27" height="13" viewBox="0 0 27 13" fill="currentColor">
            <rect x="0.5" y="0.5" width="23" height="12" rx="3.8" fill="none" stroke="currentColor" strokeOpacity="0.4" />
            <rect x="2" y="2" width="20" height="9" rx="2.4" />
            <path d="M25 4.4c.9.3 1.5 1.1 1.5 2.1s-.6 1.8-1.5 2.1z" fillOpacity="0.4" />
          </svg>
        </span>
      </div>

      {/* ダイナミックアイランド（右にカメラ） */}
      <span className="device-island" />
      {/* ホームバー */}
      <span className="device-home" />
    </div>
  )
}
