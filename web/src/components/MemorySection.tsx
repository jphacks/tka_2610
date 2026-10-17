// ⑥ 作品の詳細の「おもいで」。作品に付けた写真・動画・声の記録を並べ、足す・ひとことを変える・消すができる（Rust: backend/src/memories.rs）。
// 写真と動画は 3 列のタイル（押すと MemoryViewer で画面いっぱいに見る）、声はリストの行（押すとその場で流す。<audio> を 1 つ使い回す）。
// 「＋ 追加」のシートから、写真・動画や音声ファイルを選ぶ。選んだファイルは 1 つずつ順に送り、シートに進み具合を出す。
import { useEffect, useRef, useState } from 'react'
import {
  MEMORY_LIMITS,
  kindOfFile,
  probeMedia,
  useDeleteMemory,
  useUpdateMemory,
  useUploadMemory,
  type Memory,
  type UploadMemoryInput,
} from '../api'
import { GalleryIcon, MoreIcon, NoteIcon, PauseIcon, PlayIcon, PlusIcon, VideoIcon } from '../icons'
import { MemoryViewer } from './MemoryViewer'
import { Sheet } from './Sheet'
import { useToast } from './Toast'
import './MemorySection.css'

/** 送っているファイル 1 つ（シートに出す） */
interface Job {
  key: number
  name: string
  ratio: number
  error?: string
}

/** 声の再生（<audio> を 1 つ使い回す。画面を離れたら止める） */
function useVoicePlayer(onError: () => void) {
  const audio = useRef<HTMLAudioElement | null>(null)
  const [playing, setPlaying] = useState<string | null>(null)
  const [progress, setProgress] = useState(0)

  useEffect(() => () => audio.current?.pause(), [])

  const stop = () => {
    audio.current?.pause()
    setPlaying(null)
    setProgress(0)
  }
  const toggle = (memory: Memory) => {
    if (playing === memory.id) return stop()
    let a = audio.current
    if (!a) {
      a = new Audio()
      audio.current = a
      const el = a
      el.ontimeupdate = () => setProgress(el.duration && Number.isFinite(el.duration) ? el.currentTime / el.duration : 0)
      el.onended = () => {
        setPlaying(null)
        setProgress(0)
      }
    }
    a.src = memory.url
    setProgress(0)
    setPlaying(memory.id)
    a.play().catch(() => {
      setPlaying(null)
      onError()
    })
  }
  return { playing, progress, toggle, stop }
}

export function MemorySection({ artworkId, memories }: { artworkId: string; memories: Memory[] }) {
  const toast = useToast()
  const upload = useUploadMemory(artworkId)
  const update = useUpdateMemory(artworkId)
  const remove = useDeleteMemory(artworkId)
  const voice = useVoicePlayer(() => toast('この端末では、この声を再生できません'))
  const visuals = memories.filter((m) => m.kind !== 'audio')
  const voices = memories.filter((m) => m.kind === 'audio')

  const [adding, setAdding] = useState(false)
  const [jobs, setJobs] = useState<Job[]>([])
  const busy = jobs.some((j) => !j.error && j.ratio < 1)
  const [viewing, setViewing] = useState<number | null>(null)
  // 「⋯」で選んだおもいでと、そのあとの操作
  const [target, setTarget] = useState<{ memory: Memory; mode: 'menu' | 'edit' | 'delete' } | null>(null)
  const pickVisual = useRef<HTMLInputElement>(null)
  const pickAudio = useRef<HTMLInputElement>(null)

  /** ファイルを 1 つずつ順に送る。全部送れたらシートを閉じる。送れなかったものはシートに理由を残す */
  const send = async (inputs: { input: UploadMemoryInput; name: string }[]) => {
    const base = Date.now()
    setJobs(inputs.map((x, i) => ({ key: base + i, name: x.name, ratio: 0 })))
    const patch = (key: number, value: Partial<Job>) => setJobs((all) => all.map((j) => (j.key === key ? { ...j, ...value } : j)))
    let failed = 0
    for (const [i, { input }] of inputs.entries()) {
      const key = base + i
      const kind = kindOfFile(input.file) ?? 'video'
      if (input.file.size > MEMORY_LIMITS[kind]) {
        failed++
        patch(key, { error: `${MEMORY_LIMITS[kind] / 1024 / 1024} MB までです` })
        continue
      }
      try {
        await upload.mutateAsync({ input, onProgress: (ratio) => patch(key, { ratio: Math.min(ratio, 0.99) }) })
        patch(key, { ratio: 1 })
      } catch (e) {
        failed++
        patch(key, { error: e instanceof Error ? e.message : '送れませんでした' })
      }
    }
    if (failed === 0) {
      setAdding(false)
      setJobs([])
      toast(inputs.length === 1 ? 'おもいでを足しました' : `おもいでを ${inputs.length} つ足しました`)
    }
  }

  const onFiles = async (files: FileList | null) => {
    if (!files?.length) return
    const list = Array.from(files)
    const inputs = await Promise.all(list.map(async (file) => ({ name: file.name, input: { file, ...(await probeMedia(file)) } })))
    await send(inputs)
  }

  const closeAdding = () => {
    if (busy) return
    setAdding(false)
    setJobs([])
  }

  const saveCaption = (memory: Memory, caption: string) =>
    update.mutate(
      { id: memory.id, caption },
      {
        onSuccess: () => {
          setTarget(null)
          toast('ひとことを変えました')
        },
        onError: (e) => toast(e.message),
      },
    )

  const deleteMemory = (memory: Memory) =>
    remove.mutate(memory.id, {
      onSuccess: () => {
        setTarget(null)
        if (voice.playing === memory.id) voice.stop()
        // 見ていた写真・動画を消したら、前のものを出す（無くなったら閉じる）
        if (viewing !== null) {
          const rest = visuals.length - 1
          setViewing(rest > 0 ? Math.min(viewing, rest - 1) : null)
        }
        toast('おもいでを消しました')
      },
      onError: (e) => toast(e.message),
    })

  return (
    <section className="memories">
      <div className="section-head">
        <h2>
          おもいで{memories.length > 0 && <span className="memories-count num">{memories.length}</span>}
        </h2>
        <button type="button" className="btn btn-plain memories-add" onClick={() => setAdding(true)}>
          <PlusIcon size={16} strokeWidth={2.2} />
          追加
        </button>
      </div>

      {memories.length === 0 && (
        <button type="button" className="memories-empty" onClick={() => setAdding(true)}>
          <span className="memories-empty-icons" aria-hidden="true">
            <GalleryIcon size={20} />
            <VideoIcon size={20} />
            <NoteIcon size={20} />
          </span>
          作っているところの動画や写真、子どもの声を残せます
        </button>
      )}

      {visuals.length > 0 && (
        <div className="memory-grid">
          {visuals.map((m, i) => (
            <button key={m.id} type="button" className="memory-tile" onClick={() => setViewing(i)} aria-label={m.caption || (m.kind === 'photo' ? '写真' : '動画')}>
              {m.kind === 'photo' ? (
                <img src={m.thumb_url ?? m.url} alt="" loading="lazy" decoding="async" />
              ) : (
                <>
                  <VideoIcon size={26} className="memory-tile-fallback" />
                  {/* 最初のコマを出す（読めない形式なら下のアイコンが見える） */}
                  <video src={`${m.url}#t=0.1`} preload="metadata" muted playsInline tabIndex={-1} />
                  <span className="memory-tile-badge num">
                    <PlayIcon size={11} />
                    {m.duration_label ?? '動画'}
                  </span>
                </>
              )}
            </button>
          ))}
        </div>
      )}

      {voices.length > 0 && (
        <div className="list-group memory-voices">
          {voices.map((m) => {
            const playing = voice.playing === m.id
            return (
              <div key={m.id} className="list-item memory-voice">
                <button
                  type="button"
                  className={`memory-voice-play${playing ? ' playing' : ''}`}
                  aria-label={playing ? '止める' : '声をきく'}
                  onClick={() => voice.toggle(m)}
                >
                  {playing ? <PauseIcon size={16} /> : <PlayIcon size={16} />}
                </button>
                <div className="grow">
                  <p className="memory-voice-title">{m.caption || '声の記録'}</p>
                  <p className="memory-voice-meta num">{[m.duration_label, m.date_label].filter(Boolean).join('・')}</p>
                  {playing && (
                    <span className="memory-voice-bar">
                      <span style={{ width: `${voice.progress * 100}%` }} />
                    </span>
                  )}
                </div>
                <button type="button" className="icon-btn memory-voice-more" aria-label="メニュー" onClick={() => setTarget({ memory: m, mode: 'menu' })}>
                  <MoreIcon size={18} />
                </button>
              </div>
            )
          })}
        </div>
      )}

      {viewing !== null && (
        <MemoryViewer
          items={visuals}
          index={viewing}
          onIndex={setViewing}
          onClose={() => setViewing(null)}
          onMenu={(memory) => setTarget({ memory, mode: 'menu' })}
        />
      )}

      {/* 追加のシート。ファイルを選ぶ入力は見えないようにして、ボタンから開く */}
      <input
        ref={pickVisual}
        className="visually-hidden"
        type="file"
        accept="image/*,video/*"
        multiple
        onChange={(e) => {
          onFiles(e.target.files)
          e.target.value = ''
        }}
      />
      <input
        ref={pickAudio}
        className="visually-hidden"
        type="file"
        accept="audio/*"
        multiple
        onChange={(e) => {
          onFiles(e.target.files)
          e.target.value = ''
        }}
      />
      <Sheet open={adding} onClose={closeAdding} title="おもいでを足す">
        {jobs.length > 0 ? (
          <div className="sheet-body">
            <ul className="memory-jobs">
              {jobs.map((j) => (
                <li key={j.key} className={j.error ? 'failed' : undefined}>
                  <span className="memory-job-name">{j.name}</span>
                  {j.error ? (
                    <span className="memory-job-error">{j.error}</span>
                  ) : (
                    <span className="memory-voice-bar">
                      <span style={{ width: `${j.ratio * 100}%` }} />
                    </span>
                  )}
                </li>
              ))}
            </ul>
            {!busy && (
              <button className="btn btn-gray" onClick={closeAdding}>
                閉じる
              </button>
            )}
          </div>
        ) : (
          <div className="sheet-body">
            <button className="btn btn-filled" onClick={() => pickVisual.current?.click()}>
              <GalleryIcon size={19} />
              写真・動画をえらぶ
            </button>
            <button className="btn btn-outline" onClick={() => pickAudio.current?.click()}>
              <NoteIcon size={19} />
              音声ファイルをえらぶ
            </button>
            <p className="hint" style={{ margin: 0, textAlign: 'center' }}>
              動画は 100 MB、写真と声は 20 MB まで。1 つの作品に 30 個まで残せます
            </p>
          </div>
        )}
      </Sheet>

      {/* 「⋯」：ひとことを変える・消す */}
      <Sheet open={target?.mode === 'menu'} onClose={() => setTarget(null)} title="このおもいで">
        <div className="sheet-body">
          <button className="btn btn-gray" onClick={() => target && setTarget({ ...target, mode: 'edit' })}>
            ひとことを変える
          </button>
          <button className="btn btn-destructive" onClick={() => target && setTarget({ ...target, mode: 'delete' })}>
            消す
          </button>
        </div>
      </Sheet>
      <Sheet open={target?.mode === 'edit'} onClose={() => setTarget(null)} title="ひとこと">
        {target && (
          <form
            className="sheet-body"
            onSubmit={(e) => {
              e.preventDefault()
              saveCaption(target.memory, String(new FormData(e.currentTarget).get('caption') ?? ''))
            }}
          >
            <input
              key={target.memory.id}
              name="caption"
              className="input"
              maxLength={80}
              defaultValue={target.memory.caption}
              placeholder="例）できあがって、うれしくておどったよ"
            />
            <button className="btn btn-filled" disabled={update.isPending}>
              保存
            </button>
          </form>
        )}
      </Sheet>
      <Sheet open={target?.mode === 'delete'} onClose={() => setTarget(null)} title="このおもいでを消しますか？">
        <p className="hint" style={{ textAlign: 'center', margin: '4px 8px 0' }}>
          ファイルも消えます。この操作は取り消せません。
        </p>
        <div className="sheet-body">
          <button className="btn btn-destructive" disabled={remove.isPending} onClick={() => target && deleteMemory(target.memory)}>
            消す
          </button>
          <button className="btn btn-gray" onClick={() => setTarget(null)}>
            キャンセル
          </button>
        </div>
      </Sheet>
    </section>
  )
}
