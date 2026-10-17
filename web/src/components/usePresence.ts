import { useEffect, useState } from 'react'

/**
 * 開閉アニメーション用。open が false になっても、閉じるアニメーション（exitMs）が
 * 終わるまで DOM に残す。mounted で描画するか、visible で「開いた見た目」にするかを決める。
 * トースト・コンテキストメニュー・シートで使う。
 */
export function usePresence(open: boolean, exitMs = 260) {
  const [mounted, setMounted] = useState(open)
  const [visible, setVisible] = useState(open)

  useEffect(() => {
    if (open) {
      setMounted(true)
      const raf = requestAnimationFrame(() => requestAnimationFrame(() => setVisible(true)))
      return () => cancelAnimationFrame(raf)
    }
    setVisible(false)
    const t = window.setTimeout(() => setMounted(false), exitMs)
    return () => window.clearTimeout(t)
  }, [open, exitMs])

  return { mounted, visible }
}
