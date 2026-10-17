// トースト（画面上部から降りてくるバナー）。useToast() で取得した関数に文言を渡すと表示する。
import { createContext, useCallback, useContext, useRef, useState, type ReactNode } from 'react'
import { usePresence } from './usePresence'
import './Toast.css'

const ToastContext = createContext<(message: string) => void>(() => {})

export function ToastProvider({ children }: { children: ReactNode }) {
  const [message, setMessage] = useState<string | null>(null)
  const [open, setOpen] = useState(false)
  const timer = useRef<number | undefined>(undefined)
  const { mounted, visible } = usePresence(open, 300)

  const show = useCallback((text: string) => {
    setMessage(text)
    setOpen(true)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(() => setOpen(false), 2400)
  }, [])

  return (
    <ToastContext.Provider value={show}>
      {children}
      {mounted && (
        <div className={`banner glass-dark${visible ? ' in' : ''}`} role="status">
          {message}
        </div>
      )}
    </ToastContext.Provider>
  )
}

export const useToast = () => useContext(ToastContext)
