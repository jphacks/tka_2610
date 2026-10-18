// 声を録音するシート（⑥ 作品の詳細の「おもいで」→「声を録音する」）。
// 大きなマイクのボタンで録音をはじめ、止めるとその場で聞き直せる。ひとことを付けて「保存」すると onSave（送るのは MemorySection）。
// 録音はブラウザの MediaRecorder。形式は audio/mp4（Safari・新しい Chrome。どの端末でも流れる）を先に試し、だめなら webm・ogg。
// 長さは録音した時間（webm には長さが書かれないため）。3 分で自動で止める。
// マイクは https か localhost で開いたときだけ使える（LAN の IP の http では使えない）。使えないときは理由を出し、音声ファイルを選ぶ方へ誘う。
import { useEffect, useRef, useState } from 'react'
import type { UploadMemoryInput } from '../api'
import { MicIcon, StopIcon } from '../icons'
import { Sheet } from './Sheet'
import './VoiceRecorder.css'

/** 録音の長さの上限（ミリ秒） */
const MAX_MS = 3 * 60 * 1000
const TYPES = ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus']

type Phase =
  | { kind: 'idle' }
  | { kind: 'recording'; startedAt: number }
  | { kind: 'review'; blob: Blob; url: string; durationMs: number }
  | { kind: 'error'; message: string }

/** "1:05" */
const clock = (ms: number) => {
  const s = Math.floor(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

const fileNameOf = (type: string) => (type.includes('mp4') ? 'voice.m4a' : type.includes('ogg') ? 'voice.ogg' : 'voice.webm')

export function VoiceRecorder({
  open,
  onClose,
  onSave,
  onPickFile,
  saving,
}: {
  open: boolean
  onClose: () => void
  onSave: (input: UploadMemoryInput) => void
  /** マイクが使えないときに、音声ファイルを選ぶ */
  onPickFile: () => void
  saving: boolean
}) {
  const [phase, setPhase] = useState<Phase>({ kind: 'idle' })
  const [now, setNow] = useState(0)
  const recorder = useRef<MediaRecorder | null>(null)
  const stream = useRef<MediaStream | null>(null)
  const discard = useRef(false)

  const release = () => {
    stream.current?.getTracks().forEach((t) => t.stop())
    stream.current = null
  }

  // 録音中は経過時間を進め、上限で止める
  useEffect(() => {
    if (phase.kind !== 'recording') return
    const timer = setInterval(() => {
      const t = Date.now()
      setNow(t)
      if (t - phase.startedAt >= MAX_MS) recorder.current?.stop()
    }, 250)
    return () => clearInterval(timer)
  }, [phase])

  // 聞き直し用の URL は、使い終わったら捨てる
  useEffect(() => {
    if (phase.kind !== 'review') return
    return () => URL.revokeObjectURL(phase.url)
  }, [phase])

  // シートを閉じたら、録音中のものは捨てて最初に戻す
  useEffect(() => {
    if (open) return
    if (recorder.current?.state === 'recording') {
      discard.current = true
      recorder.current.stop()
    }
    release()
    setPhase({ kind: 'idle' })
  }, [open])

  // 画面を離れたら、マイクを放す
  useEffect(() => () => release(), [])

  const start = async () => {
    if (!navigator.mediaDevices?.getUserMedia || typeof MediaRecorder === 'undefined') {
      setPhase({
        kind: 'error',
        message: 'この開き方ではマイクを使えません（https か localhost で開いたときだけ使えます）。録音したファイルを選んでください。',
      })
      return
    }
    try {
      stream.current = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch {
      setPhase({ kind: 'error', message: 'マイクを使えませんでした。ブラウザの設定でマイクを許可してください。' })
      return
    }
    const mimeType = TYPES.find((t) => MediaRecorder.isTypeSupported?.(t))
    const rec = new MediaRecorder(stream.current, mimeType ? { mimeType } : undefined)
    const chunks: Blob[] = []
    const startedAt = Date.now()
    rec.ondataavailable = (e) => e.data.size > 0 && chunks.push(e.data)
    rec.onstop = () => {
      release()
      if (discard.current) {
        discard.current = false
        return
      }
      const blob = new Blob(chunks, { type: rec.mimeType || mimeType || 'audio/webm' })
      setPhase({ kind: 'review', blob, url: URL.createObjectURL(blob), durationMs: Math.min(Date.now() - startedAt, MAX_MS) })
    }
    recorder.current = rec
    rec.start()
    setNow(startedAt)
    setPhase({ kind: 'recording', startedAt })
  }

  const elapsed = phase.kind === 'recording' ? Math.max(0, now - phase.startedAt) : 0

  return (
    <Sheet open={open} onClose={onClose} title="声を録音する">
      {phase.kind === 'idle' && (
        <div className="sheet-body recorder">
          <button type="button" className="recorder-mic" aria-label="録音をはじめる" onClick={start}>
            <MicIcon size={34} />
          </button>
          <p className="hint recorder-hint">押すと録音がはじまります（3 分まで）</p>
        </div>
      )}

      {phase.kind === 'recording' && (
        <div className="sheet-body recorder">
          <button type="button" className="recorder-mic recording" aria-label="録音を止める" onClick={() => recorder.current?.stop()}>
            <StopIcon size={30} />
          </button>
          <p className="recorder-clock num">
            <span className="recorder-dot" aria-hidden="true" />
            {clock(elapsed)} / {clock(MAX_MS)}
          </p>
        </div>
      )}

      {phase.kind === 'review' && (
        <form
          className="sheet-body"
          onSubmit={(e) => {
            e.preventDefault()
            const caption = String(new FormData(e.currentTarget).get('caption') ?? '').trim()
            onSave({
              file: phase.blob,
              fileName: fileNameOf(phase.blob.type),
              durationMs: phase.durationMs,
              caption: caption || undefined,
            })
          }}
        >
          <audio className="recorder-audio" src={phase.url} controls />
          <input name="caption" className="input" maxLength={80} placeholder="ひとこと（任意）例）かんらんしゃのおはなし" />
          <button className="btn btn-filled" disabled={saving}>
            {saving ? '保存しています…' : '保存'}
          </button>
          <button type="button" className="btn btn-gray" disabled={saving} onClick={() => setPhase({ kind: 'idle' })}>
            録り直す
          </button>
        </form>
      )}

      {phase.kind === 'error' && (
        <div className="sheet-body">
          <p className="hint" style={{ margin: 0, textAlign: 'center' }}>
            {phase.message}
          </p>
          <button className="btn btn-filled" onClick={onPickFile}>
            音声ファイルをえらぶ
          </button>
          <button className="btn btn-gray" onClick={() => setPhase({ kind: 'idle' })}>
            もう一度ためす
          </button>
        </div>
      )}
    </Sheet>
  )
}
