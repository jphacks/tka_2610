// シアターの再生の時計と、音（BGM・動画・声）の合わせ方。
//
// 時計（clock、ミリ秒）は 1 本だけ。requestAnimationFrame で進め、3D（TheaterScene）は毎フレームそれを読む。
// BGM・動画・声は、時計から「いまどこを流しているべきか」を求め、0.3 秒よりずれたら合わせ直す。
// だから、止める・シークする・前後の作品へ飛ぶ、のどれをしても音と映像がずれない。
// 作品の 3D を読み込み中のあいだは、作品が着いた時刻で時計を止めて待つ（読めなければ 12 秒で写真に替わる）。
// 動画の音や声が鳴っているあいだは、BGM を小さくする（ダッキング）。最後の余韻では BGM を小さくして終わる。
import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'
import type { TheaterData } from '../api'
import { frameAt, memoLineAt, type TheaterPhase } from '../three'

export interface PlaybackView {
  index: number
  phase: TheaterPhase
  /** メモの見えている行（無ければ -1） */
  line: number
  /** 再生位置（0.25 秒ごとに更新。シークバーの表示用） */
  time: number
  /** 作品の 3D を読み込み中で、時計を止めて待っている */
  waiting: boolean
  ended: boolean
  /** 動画か声の音が鳴っている */
  mediaAudible: boolean
}

export interface PlaybackOptions {
  musicUrl: string | null
  musicOffset: number
  volume: number
  mediaSound: boolean
  loaded: Record<string, boolean>
  /** 進む速さ。data はこの速さに合わせて時刻を縮めたもの（scaleTheater）を渡す */
  speed: number
}

const DRIFT = 0.3
/** 時計が BGM から遅れた・進んだ分を、1 フレームにつきこの割合ずつ取り戻す（1 秒ほどで追いつく） */
const BGM_FOLLOW = 0.08
/** BGM とこれ以上ずれたら、少しずつではなく一度で合わせる（ミリ秒）。曲を引き戻す DRIFT（0.3 秒）より小さくして、曲が飛ばないようにする */
const BGM_SNAP_MS = 250
const clamp01 = (x: number) => Math.min(1, Math.max(0, x))

export function useTheaterPlayback(data: TheaterData | undefined, options: PlaybackOptions) {
  const clock = useRef(0)
  const [playing, setPlayingState] = useState(false)
  const playingRef = useRef(false)
  const [version, setVersion] = useState(0)
  const [view, setView] = useState<PlaybackView>({ index: 0, phase: 'intro', line: -1, time: 0, waiting: false, ended: false, mediaAudible: false })
  const opts = useRef(options)
  opts.current = options

  const setPlaying = useCallback((value: boolean) => {
    playingRef.current = value
    setPlayingState(value)
  }, [])

  // BGM（選んだ音源）
  const bgm = useRef<HTMLAudioElement | null>(null)
  useEffect(() => {
    if (!options.musicUrl) { bgm.current = null; return }
    const audio = new Audio(options.musicUrl)
    audio.loop = true
    audio.preload = 'auto'
    audio.volume = 0
    bgm.current = audio
    return () => { audio.pause(); audio.removeAttribute('src'); audio.load(); if (bgm.current === audio) bgm.current = null }
  }, [options.musicUrl])
  const gain = useRef(0)
  /** 前のフレームの BGM の再生位置（時計を BGM に合わせて進めるため） */
  const lastBgm = useRef<number | null>(null)
  /** BGM が時計より先に進んでいる量（ミリ秒）。毎フレーム少しずつ時計に足して、なめらかに追いつく */
  const bgmLead = useRef(0)
  /** 作品の読み込みを待っていたあいだの長さ。そのあいだも BGM は止めずに流すので、曲の位置をこの分だけ先へずらす */
  const waitShift = useRef(0)

  // 声（作品の最初の声）
  const voice = useRef<HTMLAudioElement | null>(null)
  useEffect(() => {
    const audio = new Audio()
    audio.preload = 'auto'
    voice.current = audio
    return () => { audio.pause(); audio.removeAttribute('src'); voice.current = null }
  }, [])

  // 動画（写真立てに貼る要素。3D が VideoTexture にする）
  const videos = useRef(new Map<string, HTMLVideoElement>())
  const videoUrls = useMemo(() => {
    const map = new Map<string, string>()
    data?.scenes.forEach((s) => s.media.forEach((m) => { if (m.memory.kind === 'video') map.set(m.memory.id, m.memory.url) }))
    return map
  }, [data])
  const videoFor = useCallback((id: string) => {
    let video = videos.current.get(id)
    if (!video) {
      const url = videoUrls.get(id)
      if (!url) return null
      video = document.createElement('video')
      video.playsInline = true
      video.muted = true
      video.preload = 'auto'
      video.crossOrigin = 'anonymous'
      video.src = url
      videos.current.set(id, video)
    }
    return video
  }, [videoUrls])
  useEffect(() => () => {
    videos.current.forEach((v) => { v.pause(); v.removeAttribute('src'); v.load() })
    videos.current.clear()
  }, [videoUrls])

  // 進む速さを変えたら、いま見ている所のまま続ける（時計を新しい時間割に読み替える）。
  // 曲は止めずにそのまま流すので、時計が縮んだ分を waitShift に足して、曲の位置が飛ばないようにする
  const clockSpeed = useRef(options.speed)
  useLayoutEffect(() => {
    const before = clockSpeed.current
    if (before === options.speed) return
    clockSpeed.current = options.speed
    const old = clock.current
    const next = (old * before) / options.speed
    waitShift.current += old - next
    clock.current = next
    setVersion((v) => v + 1)
  }, [options.speed])

  const seek = useCallback((t: number) => {
    if (!data) return
    if (t <= 0) waitShift.current = 0
    clock.current = Math.min(data.total_ms, Math.max(0, t))
    setVersion((v) => v + 1)
  }, [data])

  useEffect(() => {
    if (!data) return
    let raf = 0
    let last = performance.now()
    const step = (now: number) => {
      const dt = Math.min(250, now - last)
      last = now
      const o = opts.current
      let t = clock.current
      const isPlaying = playingRef.current
      const pendingAt = (time: number) => {
        const f = frameAt(data, time)
        const scene = data.scenes[f.index]
        return scene && time >= scene.arrive_ms && o.loaded[scene.artwork.id] === undefined ? scene.arrive_ms : null
      }
      let waiting = pendingAt(t) !== null
      // BGM が鳴っているあいだも、時計はフレームの長さ（dt）でなめらかに進め、BGM とのずれ（bgmLead）を少しずつ足して追いつく。
      // BGM の再生位置（currentTime）は段々にしか進まない（フレームによって 14〜17 ms、0 ms のときもある）ので、
      // そのまま時計にすると、止まらずに流れる大地がカクつく。描画が遅い端末で時計が遅れても、ずれを足すので音から離れていかない
      const b0 = bgm.current
      let advance = dt
      if (b0 && !b0.paused && b0.readyState >= 2 && lastBgm.current !== null) {
        const advanced = (b0.currentTime - lastBgm.current) * 1000
        if (advanced >= 0 && advanced < 1000) bgmLead.current += advanced - dt
        else bgmLead.current = 0
        if (Math.abs(bgmLead.current) > BGM_SNAP_MS) {
          // 大きくずれた（タブが裏にあった・端末が固まった）ときは、一度で合わせる
          advance += bgmLead.current
          bgmLead.current = 0
        } else {
          const catchUp = Math.max(-dt * 0.5, Math.min(dt * 0.5, bgmLead.current * BGM_FOLLOW))
          advance += catchUp
          bgmLead.current -= catchUp
        }
      } else bgmLead.current = 0
      advance = Math.max(0, advance)
      lastBgm.current = b0 && !b0.paused ? b0.currentTime : null
      if (isPlaying && waiting) waitShift.current += advance
      if (isPlaying && !waiting) {
        t = Math.min(data.total_ms, t + advance)
        const hold = pendingAt(t)
        if (hold !== null) { t = Math.max(clock.current, hold); waiting = true }
        clock.current = t
      }
      const ended = data.total_ms > 0 && t >= data.total_ms
      if (ended && isPlaying) { playingRef.current = false; setPlayingState(false) }
      const active = playingRef.current && !waiting

      const f = frameAt(data, t)
      const scene = data.scenes[f.index]
      const showing = f.phase === 'hold' || f.phase === 'outro'
      let audible = false

      // 動画：その写真立てが立っていて、流す長さのうちだけ再生する
      for (const [id, video] of videos.current) {
        const slot = scene?.media.find((m) => m.memory.id === id)
        let want = false
        let pos = 0
        if (slot && slot.play_ms && showing) {
          const local = f.local - slot.show_ms
          if (local >= 0 && local < slot.play_ms && f.local < slot.hide_ms) { want = true; pos = local / 1000 }
        }
        video.muted = !o.mediaSound
        const playable = !video.error && (!Number.isFinite(video.duration) || pos < video.duration)
        if (want && playable) {
          if (video.readyState >= 1 && Math.abs(video.currentTime - pos) > DRIFT) video.currentTime = pos
          if (active) {
            if (video.paused) void video.play().catch(() => {})
            if (o.mediaSound && !video.paused) audible = true
          } else if (!video.paused) video.pause()
        } else if (!video.paused) video.pause()
      }

      // 声
      const v = voice.current
      if (v) {
        const clip = scene?.voice
        const local = f.local - (scene?.voice_at_ms ?? 0)
        const want = !!clip && o.mediaSound && showing && local >= 0 && local < (scene?.voice_ms ?? 0)
        if (want && clip) {
          if (!v.src.endsWith(clip.url)) v.src = clip.url
          const pos = local / 1000
          if (v.readyState >= 1 && Math.abs(v.currentTime - pos) > DRIFT && (!Number.isFinite(v.duration) || pos < v.duration)) v.currentTime = pos
          if (active) { if (v.paused && !v.ended) void v.play().catch(() => {}); if (!v.paused) audible = true }
          else if (!v.paused) v.pause()
        } else if (!v.paused) v.pause()
      }

      // BGM：曲の offset 秒から流し、曲が終わったら offset へ戻る
      const b = bgm.current
      if (b) {
        const fadeOut = data.total_ms > 0 ? clamp01((data.total_ms - t) / Math.max(1, data.outro_ms)) : 1
        const target = o.volume * (audible ? 0.25 : 1) * fadeOut
        gain.current += (target - gain.current) * Math.min(1, dt / 220)
        b.volume = clamp01(gain.current)
        if (playingRef.current && !ended) {
          const duration = b.duration
          const offset = Math.max(0, o.musicOffset)
          const played = (t + waitShift.current) / 1000
          let pos = offset + played
          if (Number.isFinite(duration) && duration > 0) {
            const span = duration - offset
            pos = span > 1 ? offset + (played % span) : played % duration
          }
          if (b.readyState >= 1 && Math.abs(b.currentTime - pos) > DRIFT) { b.currentTime = pos; lastBgm.current = null }
          if (b.paused) void b.play().catch(() => {})
        } else if (!b.paused) b.pause()
      }

      const line = scene && showing ? memoLineAt(scene, f.local) : -1
      const time = Math.floor(t / 250) * 250
      setView((prev) =>
        prev.index === f.index && prev.phase === f.phase && prev.line === line && prev.time === time && prev.waiting === waiting && prev.ended === ended && prev.mediaAudible === audible
          ? prev
          : { index: Math.max(0, f.index), phase: f.phase, line, time, waiting, ended, mediaAudible: audible },
      )
      raf = requestAnimationFrame(step)
    }
    raf = requestAnimationFrame(step)
    return () => cancelAnimationFrame(raf)
  }, [data])

  // 遠くの場面の動画は、読み込んだものを手放す
  useEffect(() => {
    if (!data) return
    const keep = new Set<string>()
    for (const i of [view.index - 1, view.index, view.index + 1]) data.scenes[i]?.media.forEach((m) => keep.add(m.memory.id))
    for (const [id, video] of videos.current) {
      if (keep.has(id)) continue
      video.pause()
      video.removeAttribute('src')
      video.load()
      videos.current.delete(id)
    }
  }, [data, view.index])

  // 画面を閉じたら全部止める
  useEffect(() => () => {
    playingRef.current = false
    bgm.current?.pause()
    voice.current?.pause()
    videos.current.forEach((v) => v.pause())
  }, [])

  return { clock, playing, setPlaying, seek, version, view, videoFor }
}
