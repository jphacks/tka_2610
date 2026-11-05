// ⑥ 作品の詳細の「おもいで」。作品に付けた写真・動画・声の記録を並べ、足す・ひとことを変える・消すができる（Rust: backend/src/memories.rs）。
// 写真と動画は 3 列のタイル（押すと MemoryViewer で画面いっぱいに見る）、声はリストの行（押すとその場で流す。<audio> を 1 つ使い回す）。
// 「＋ 追加」のシートから、写真・動画や音声ファイルを選ぶ・声を録音する（VoiceRecorder）。選んだファイルは 1 つずつ順に送り、シートに進み具合を出す。
// スマホなど指で操作する端末では、「写真をとる」「動画をとる」でその場でカメラを開ける（capture 付きの入力。PC では効かないので出さない）。
import { useEffect, useMemo, useRef, useState } from 'react'
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
import { CameraIcon, CloseIcon, GalleryIcon, MicIcon, MoreIcon, NoteIcon, PauseIcon, PlayIcon, PlusIcon, VideoIcon } from '../icons'
import { MemoryViewer } from './MemoryViewer'
import { ArtworkMemo } from './ArtworkMemo'
import { PhotoEditor } from './PhotoEditor'
import { Sheet } from './Sheet'
import { useToast } from './Toast'
import { VoiceRecorder } from './VoiceRecorder'
import './MemorySection.css'

/** その場で撮れる端末か（指で操作する端末。PC のブラウザは capture を無視してファイルを選ばせるだけなので出さない） */
const canCapture = () => typeof window !== 'undefined' && !!window.matchMedia?.('(pointer: coarse)').matches

/** 送っているファイル 1 つ（シートに出す） */
interface Job {
  key: number
  name: string
  ratio: number
  error?: string
}

/** 確認のシートに出す、選んだ写真 1 枚 (original は選んだままの写真、file は今の写真。直したら file が変わる) */
interface ReviewItem {
  id: number
  original: File
  file: File
}

/** 選んだ写真の小さい表示（ファイルから仮の URL を作って、使い終わったら捨てる） */
function ReviewThumb({ file }: { file: File }) {
  const [url, setUrl] = useState<string | null>(null)
  useEffect(() => {
    const u = URL.createObjectURL(file)
    setUrl(u)
    return () => URL.revokeObjectURL(u)
  }, [file])
  return url ? <img src={url} alt="" /> : null
}

/** 声の波形の縦線の数 */
const WAVE_BARS = 22

/** 声の記録の id から、いつも同じ形の縦線の高さ（0.25〜1）を作る。本当の音の大きさは測らない、見た目の波形 */
function waveHeights(id: string): number[] {
  let x = 2166136261
  for (const c of id) x = Math.imul(x ^ c.charCodeAt(0), 16777619)
  return Array.from({ length: WAVE_BARS }, () => {
    x ^= x << 13
    x ^= x >>> 17
    x ^= x << 5
    return 0.25 + 0.75 * (((x >>> 0) % 1000) / 1000)
  })
}

/** 声のカードの縦線の波形。流しているところまでの線が濃くなる（progress は 0〜1） */
function Waveform({ id, progress }: { id: string; progress: number }) {
  const heights = useMemo(() => waveHeights(id), [id])
  const played = Math.round(progress * heights.length)
  return (
    <span className="memory-wave" aria-hidden="true">
      {heights.map((h, i) => (
        <i key={i} className={i < played ? 'on' : undefined} style={{ height: `${h * 100}%` }} />
      ))}
    </span>
  )
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




export function MemorySection({
  artworkId,
  memories,
  memo,
}: {
  artworkId: string
  memories: Memory[]
  memo?: string | null
}) {
  const toast = useToast()
  const upload = useUploadMemory(artworkId)
  const update = useUpdateMemory(artworkId)
  const remove = useDeleteMemory(artworkId)
  const voice = useVoicePlayer(() =>
    toast('この端末では、この声を再生できません')
  )

  const visuals = memories.filter((m) => m.kind !== 'audio')
  const voices = memories.filter((m) => m.kind === 'audio')
  const [adding, setAdding] = useState(false)
  const [recording, setRecording] = useState(false)
  const [jobs, setJobs] = useState<Job[]>([])
  // 「向きをなおす・切り取る」を開いている写真。index が null なら 1 枚だけ選んだとき (直したらそのまま足す)、数なら確認のシートの何番目か
  // replace があるときは、足したあとの写真を直しているところ (直したら、その写真に置き換える)
  const [editing, setEditing] = useState<{ file: File; index: number | null; replace?: Memory } | null>(null)
  // 写真を 2 枚以上選んだときの確認のシート。直したい写真だけ直して、まとめて足す (others は、いっしょに選んだ動画・声)
  const [review, setReview] = useState<{ items: ReviewItem[]; others: File[] } | null>(null)
  const busy = jobs.some((j) => !j.error && j.ratio < 1)
  const [viewing, setViewing] = useState<number | null>(null)
  // 「⋯」で選んだおもいでと、そのあとの操作
  const [target, setTarget] = useState<{ memory: Memory; mode: 'menu' | 'edit' | 'delete' } | null>(null)
  const pickVisual = useRef<HTMLInputElement>(null)
  const pickAudio = useRef<HTMLInputElement>(null)
  const takePhoto = useRef<HTMLInputElement>(null)
  const takeVideo = useRef<HTMLInputElement>(null)
  const camera = canCapture()

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
    const photos = list.filter((f) => kindOfFile(f) === 'photo')
    // 写真を 1 枚だけ選んだときは、すぐ「向きをなおす・切り取る」を開く
    if (list.length === 1 && photos.length === 1) return setEditing({ file: photos[0], index: null })
    // 写真を 2 枚以上選んだときは、足す前の確認のシートで、直したい写真だけ直せる
    if (photos.length >= 2) {
      const base = Date.now()
      setReview({
        items: photos.map((file, i) => ({ id: base + i, original: file, file })),
        others: list.filter((f) => kindOfFile(f) !== 'photo'),
      })
      return
    }
    await sendFiles(list)
  }

  /** 足したあとの写真を「向きをなおす・切り取る」で開く。写真を読み込んで、シートに渡す */
  const startEditPhoto = async (memory: Memory) => {
    setTarget(null)
    try {
      const res = await fetch(memory.url)
      if (!res.ok) throw new Error('read')
      const blob = await res.blob()
      setEditing({ file: new File([blob], `${memory.id}.jpg`, { type: blob.type || 'image/jpeg' }), index: null, replace: memory })
    } catch {
      toast('写真を読み込めませんでした')
    }
  }

  /**
   * 直した写真に置き換える。サーバーには「差し替え」が無いので、直した写真を新しく足してから、前の写真を消す
   * (足すのに失敗したら、前の写真はそのまま。ひとことは引きつぐ。並びは、いちばん後ろになる)
   */
  const replacePhoto = async (old: Memory, photo: File) => {
    setViewing(null)
    toast('写真を直しています…')
    try {
      await upload.mutateAsync({ input: { file: photo, caption: old.caption || undefined } })
    } catch (e) {
      return toast(e instanceof Error ? e.message : '写真を直せませんでした')
    }
    try {
      await remove.mutateAsync(old.id)
      toast('写真を直しました')
    } catch {
      toast('直した写真を足しましたが、前の写真を消せませんでした。前の写真は、自分で消してください')
    }
  }

  /** 確認のシートの「この内容で追加」：写真 (直したものを含む) と、いっしょに選んだ動画・声を、順に送る */
  const confirmReview = async () => {
    if (!review) return
    const list = [...review.items.map((i) => i.file), ...review.others]
    setReview(null)
    await sendFiles(list)
  }

  const removeReviewItem = (id: number) =>
    setReview((r) => {
      if (!r) return r
      const items = r.items.filter((i) => i.id !== id)
      return items.length === 0 && r.others.length === 0 ? null : { ...r, items }
    })

  const sendFiles = async (list: File[]) => {
    const inputs = await Promise.all(list.map(async (file) => ({ name: file.name, input: { file, ...(await probeMedia(file)) } })))
    await send(inputs)
  }

  /** 録音した声を送る（進み具合は出さず、録音のシートに「保存しています…」を出す） */
  const saveVoice = async (input: UploadMemoryInput) => {
    try {
      await upload.mutateAsync({ input })
      setRecording(false)
      toast('声を残しました')
    } catch (e) {
      toast(e instanceof Error ? e.message : '送れませんでした')
    }
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
          toast('ひとことを保存しました')
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

      
{/* 短いメモと声1件は横並び。長文・改行が多いメモや複数の声は横幅を使う */}
  <div className={`memory-keepsakes${voices.length > 1 || Array.from(memo ?? '').length > 80 || (memo ?? '').split('\n').length > 3 ? ' memory-keepsakes-stacked' : ''}`}>
    {voices.length > 0 && (
      <div className="list-group memory-voices">
        {voices.map((m) => {
          const playing = voice.playing === m.id

          return (
            <div
              key={m.id}
              className="list-item memory-voice"
            >
              <button
                type="button"
                className={`memory-voice-play${playing ? ' playing' : ''}`}
                aria-label={playing ? '止める' : '声をきく'}
                onClick={() => voice.toggle(m)}
              >
                {playing ? (
                  <PauseIcon size={16} />
                ) : (
                  <PlayIcon size={16} />
                )}
              </button>

              <div className="grow">
                {m.caption && (
                  <p className="memory-voice-title">
                    {m.caption}
                  </p>
                )}

                <Waveform id={m.id} progress={playing ? voice.progress : 0} />

                <p className="memory-voice-meta num">
                  {[m.duration_label, m.date_label?.replace(/^\d{4}年/, '')]
                    .filter(Boolean)
                    .join('・')}
                </p>

              </div>

              <button
                type="button"
                className="icon-btn memory-voice-more"
                aria-label="メニュー"
                onClick={() =>
                  setTarget({
                    memory: m,
                    mode: 'menu',
                  })
                }
              >
                <MoreIcon size={18} />
              </button>
            </div>
          )
        })}
      </div>
    )}

    <ArtworkMemo key={artworkId} artworkId={artworkId} memo={memo ?? ''} />
  </div>


      {viewing !== null && (
        <MemoryViewer
          items={visuals}
          index={viewing}
          onIndex={setViewing}
          onClose={() => setViewing(null)}
          onMenu={(memory) => setTarget({ memory, mode: 'menu' })}
        />
      )}

      {/* 追加のシート。ファイルを選ぶ入力は見えないようにして、ボタンから開く（撮る 2 つは、外側のカメラをすぐ開く） */}
      {[
        { ref: takePhoto, accept: 'image/*' },
        { ref: takeVideo, accept: 'video/*' },
      ].map(({ ref, accept }) => (
        <input
          key={accept}
          ref={ref}
          className="visually-hidden"
          type="file"
          accept={accept}
          capture="environment"
          onChange={(e) => {
            onFiles(e.target.files)
            e.target.value = ''
          }}
        />
      ))}
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
            {camera && (
              <div className="memory-capture">
                <button className="btn btn-filled" onClick={() => takePhoto.current?.click()}>
                  <CameraIcon size={19} />
                  写真をとる
                </button>
                <button className="btn btn-filled" onClick={() => takeVideo.current?.click()}>
                  <VideoIcon size={19} />
                  動画をとる
                </button>
              </div>
            )}
            <button className={`btn ${camera ? 'btn-outline' : 'btn-filled'}`} onClick={() => pickVisual.current?.click()}>
              <GalleryIcon size={19} />
              {camera ? 'ライブラリからえらぶ' : '写真・動画をえらぶ'}
            </button>
            <button
              className="btn btn-outline"
              onClick={() => {
                setAdding(false)
                setRecording(true)
              }}
            >
              <MicIcon size={19} />
              声を録音する
            </button>
            <button className="btn btn-outline" onClick={() => pickAudio.current?.click()}>
              <NoteIcon size={19} />
              音声ファイルをえらぶ
            </button>
            <p className="hint" style={{ margin: 0, textAlign: 'center' }}>
              動画は 100 MB{camera && '（スマホのカメラでおよそ 1 分）'}、写真と声は 20 MB まで。1 つの作品に 30 個まで残せます
            </p>
          </div>
        )}
      </Sheet>

      {/* 写真を 2 枚以上選んだときの確認。直したい写真をタップすると「写真を整える」が開く */}
      <Sheet open={review !== null} onClose={() => setReview(null)} title="追加する写真">
        <div className="sheet-body">
          <p className="hint" style={{ margin: 0, textAlign: 'center' }}>
            直したい写真をタップすると、向きをなおしたり、切り取ったりできます
          </p>
          <ul className="review-grid">
            {review?.items.map((item, index) => (
              <li key={item.id} className="review-tile">
                <button
                  type="button"
                  className="review-photo"
                  aria-label={`${index + 1} 枚目の写真を整える`}
                  onClick={() => setEditing({ file: item.original, index })}
                >
                  <ReviewThumb file={item.file} />
                  {item.file !== item.original && <span className="review-badge">直した</span>}
                </button>
                <button type="button" className="review-remove" aria-label="この写真を外す" onClick={() => removeReviewItem(item.id)}>
                  <CloseIcon size={12} strokeWidth={2.6} />
                </button>
              </li>
            ))}
          </ul>
          {review && review.others.length > 0 && (
            <p className="hint" style={{ margin: 0, textAlign: 'center' }}>動画・声 {review.others.length} 個も、いっしょに追加します</p>
          )}
          <button
            type="button"
            className="btn btn-filled"
            onClick={confirmReview}
            disabled={!review || review.items.length + review.others.length === 0}
          >
            この内容で追加
          </button>
          <button type="button" className="btn btn-gray" onClick={() => setReview(null)}>
            キャンセル
          </button>
        </div>
      </Sheet>

      <PhotoEditor
        file={editing?.file ?? null}
        open={editing !== null}
        onClose={() => setEditing(null)}
        onDone={(photo) => {
          if (!editing) return
          if (editing.replace) {
            // 何も直さなかったときは、そのまま
            if (photo !== editing.file) replacePhoto(editing.replace, photo)
            return
          }
          if (editing.index === null) {
            sendFiles([photo])
            return
          }
          // 確認のシートの写真を、直した写真に置き換える (直さなかったときは、選んだままの写真に戻る)
          const index = editing.index
          setReview((r) =>
            r ? { ...r, items: r.items.map((item, i) => (i === index ? { ...item, file: photo } : item)) } : r,
          )
        }}
      />

      <VoiceRecorder
        open={recording}
        onClose={() => !upload.isPending && setRecording(false)}
        onSave={saveVoice}
        onPickFile={() => {
          setRecording(false)
          setAdding(true)
          pickAudio.current?.click()
        }}
        saving={upload.isPending}
      />

      {/* 「⋯」：ひとことを変える・消す */}
      <Sheet open={target?.mode === 'menu'} onClose={() => setTarget(null)} title="このおもいで">
        <div className="sheet-body">
          {target?.memory.kind === 'photo' && (
            <button className="btn btn-filled" onClick={() => startEditPhoto(target.memory)}>
              写真を加工する
            </button>
          )}
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
