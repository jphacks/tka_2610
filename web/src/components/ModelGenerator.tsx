// ⑥ 作品の詳細の「写真から 3D を作る（試験中）」（Rust: backend/src/generator.rs。仕組みは docs/generator.md）。
// サーバーで使えるとき（GET /api/generator が enabled: true）だけ出す。本番・Cloudflare 版では何も出さない。
// 写真（1〜8 枚）と大きさ（cm）を送ると、サーバーが generator/ の kt auto で 3D を作り、作品の 3D を差し替える（写真はそのまま）。
// 作っているあいだは 3 秒ごとに様子を聞き、かかった時間を出す。終わったら作品を取り直す（上の 3D が新しいモデルに変わる）。
// 作っている job の id はこのタブの sessionStorage に覚え、詳細を開き直しても続きから様子を見る。
import { useEffect, useRef, useState, type FormEvent } from 'react'
import {
  GENERATOR_LIMITS,
  useGeneratorEnabled,
  useGeneratorJob,
  useRefreshAfterGenerate,
  useStartGenerate,
} from '../api'
import { Spinner } from './Loading'
import { Sheet } from './Sheet'
import { useToast } from './Toast'
import './ModelGenerator.css'

const ACCEPT = 'image/jpeg,image/png,image/webp'
const MB = 1024 * 1024

const storageKey = (artworkId: string) => `generator-job:${artworkId}`

function loadJobId(artworkId: string): string | null {
  try {
    return sessionStorage.getItem(storageKey(artworkId))
  } catch {
    return null
  }
}

function saveJobId(artworkId: string, jobId: string | null) {
  try {
    if (jobId) sessionStorage.setItem(storageKey(artworkId), jobId)
    else sessionStorage.removeItem(storageKey(artworkId))
  } catch {
    /* 覚えられなくても、この画面にいるあいだは様子を見られる */
  }
}

/** 秒を「1:05」の形に */
const clock = (secs: number) => `${Math.floor(secs / 60)}:${String(Math.floor(secs % 60)).padStart(2, '0')}`

export function ModelGenerator({ artworkId }: { artworkId: string }) {
  const enabled = useGeneratorEnabled()
  if (enabled.data !== true) return null
  return <GeneratorPanel artworkId={artworkId} />
}

function GeneratorPanel({ artworkId }: { artworkId: string }) {
  const toast = useToast()
  const start = useStartGenerate(artworkId)
  const refresh = useRefreshAfterGenerate(artworkId)

  const [sheet, setSheet] = useState(false)
  const [photos, setPhotos] = useState<File[]>([])
  const [size, setSize] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const [jobId, setJobId] = useState<string | null>(() => loadJobId(artworkId))
  const job = useGeneratorJob(jobId)
  const status = job.data?.status
  const running = start.isPending || status === 'running'

  // 終わった job は 1 回だけ知らせる
  const handled = useRef<string | null>(null)
  useEffect(() => {
    if (!jobId || handled.current === jobId) return
    if (status === 'done') {
      handled.current = jobId
      saveJobId(artworkId, null)
      toast('3D を作り直しました')
      void refresh()
    } else if (status === 'failed') {
      handled.current = jobId
      saveJobId(artworkId, null)
    } else if (job.isError) {
      // サーバーを起動し直すと job は消える
      handled.current = jobId
      saveJobId(artworkId, null)
    }
  }, [artworkId, jobId, status, job.isError, refresh, toast])

  // かかった時間：サーバーの秒数に、最後に聞いてからの秒数を足して 1 秒ごとに進める
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    if (status !== 'running') return
    const timer = window.setInterval(() => setNow(Date.now()), 1000)
    return () => window.clearInterval(timer)
  }, [status])
  const elapsed = job.data
    ? job.data.elapsed_secs + (status === 'running' ? Math.max(0, (now - job.dataUpdatedAt) / 1000) : 0)
    : 0

  const pick = (files: FileList | null) => {
    const list = Array.from(files ?? [])
    setFormError(null)
    if (list.length > GENERATOR_LIMITS.photos) {
      setFormError(`写真は ${GENERATOR_LIMITS.photos} 枚までです`)
      return
    }
    if (list.some((f) => f.size > GENERATOR_LIMITS.photoBytes)) {
      setFormError(`写真は 1 枚 ${GENERATOR_LIMITS.photoBytes / MB} MB までにしてください`)
      return
    }
    setPhotos(list)
  }

  const submit = (e: FormEvent) => {
    e.preventDefault()
    if (photos.length === 0) {
      setFormError('写真を 1 枚以上えらんでください')
      return
    }
    if (!size.trim()) {
      setFormError('大きさ（cm）を入れてください')
      return
    }
    setFormError(null)
    start.mutate(
      { photos, sizeCm: size },
      {
        onSuccess: (created) => {
          saveJobId(artworkId, created.job_id)
          setJobId(created.job_id)
          setSheet(false)
          setPhotos([])
        },
        onError: (error) => setFormError(error.message),
      },
    )
  }

  return (
    <section className="model-generator">
      <div className="section-head">
        <h2>写真から 3D を作る（試験中）</h2>
      </div>
      <p className="hint">
        いろいろな向きから撮った写真と実物の大きさから、この作品の 3D を作り直します。数分かかります。写真はそのままです。
      </p>

      {status === 'running' && (
        <p className="model-generator-status" role="status">
          <Spinner />
          生成中… <span className="num">{clock(elapsed)}</span>
        </p>
      )}
      {status === 'failed' && job.data?.error && (
        <p className="model-generator-error" role="alert">
          {job.data.error}
        </p>
      )}
      {jobId && job.isError && <p className="hint">生成の様子が分からなくなりました（サーバーを起動し直したときなど）。</p>}

      <button
        type="button"
        className="btn btn-outline"
        disabled={running}
        onClick={() => {
          setFormError(null)
          setSheet(true)
        }}
      >
        写真をえらんで作る
      </button>

      <Sheet open={sheet} onClose={() => setSheet(false)} title="写真から 3D を作る">
        <form className="form model-generator-form" onSubmit={submit}>
          <div className="field">
            <label htmlFor="generator-photos">写真</label>
            <input
              id="generator-photos"
              className="model-generator-file"
              type="file"
              accept={ACCEPT}
              multiple
              onChange={(e) => pick(e.target.files)}
            />
            <p className="hint">
              {photos.length > 0
                ? `${photos.length} 枚えらびました`
                : `正面・横・裏など 1〜${GENERATOR_LIMITS.photos} 枚（JPEG・PNG・WebP、1 枚 ${GENERATOR_LIMITS.photoBytes / MB} MB まで）`}
            </p>
          </div>
          <div className="field">
            <label htmlFor="generator-size">大きさ（cm）</label>
            <input
              id="generator-size"
              className="input"
              inputMode="decimal"
              placeholder="例：21, 29.7, 0.5"
              value={size}
              onChange={(e) => setSize(e.target.value)}
            />
            <p className="hint">分かっている長さを 1〜3 つ、カンマで区切って入れます（順番は問いません）。</p>
          </div>
          {formError && (
            <p className="model-generator-error" role="alert">
              {formError}
            </p>
          )}
          <div className="sheet-body">
            <button type="submit" className="btn btn-filled" disabled={start.isPending}>
              {start.isPending ? '送っています…' : '3D を作る'}
            </button>
            <button type="button" className="btn btn-gray" onClick={() => setSheet(false)}>
              キャンセル
            </button>
          </div>
        </form>
      </Sheet>
    </section>
  )
}
