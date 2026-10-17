// セグメントコントロール（iOS の切り替えボタン）。白い背景（.segmented-thumb）が選択肢へ滑って動く。
import type { CSSProperties, ReactNode } from 'react'
import './Segmented.css'

export function Segmented<T extends string>({
  options,
  value,
  onChange,
  label,
}: {
  options: { value: T; label: ReactNode }[]
  value: T
  onChange: (value: T) => void
  /** 読み上げ用のラベル */
  label: string
}) {
  const index = Math.max(0, options.findIndex((o) => o.value === value))
  return (
    <div
      className="segmented"
      role="tablist"
      aria-label={label}
      style={{ '--count': options.length, '--index': index } as CSSProperties}
    >
      <span className="segmented-thumb" aria-hidden="true" />
      {options.map((o) => (
        <button
          key={o.value}
          type="button"
          role="tab"
          aria-selected={o.value === value}
          className={o.value === value ? 'active' : ''}
          onClick={() => onChange(o.value)}
        >
          {o.label}
        </button>
      ))}
    </div>
  )
}
