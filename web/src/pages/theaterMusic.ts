// シアターの BGM（自分で選んだ音源ファイル）と設定を、この端末のブラウザにだけ覚えておく。
// 音源はサーバーへ送らない。IndexedDB に入れておき、次に開いたときも同じ曲で再生できるようにする。
// 保存できない（プライベートブラウズ・容量が足りない）ときは、覚えずにそのまま使う。

export interface TheaterMusic {
  blob: Blob
  name: string
  /** 曲のどこから使うか（秒） */
  offset: number
  /** 曲の長さ（秒。分からなければ 0） */
  duration: number
}

export interface TheaterSettings {
  volume: number
  mediaSound: boolean
  stopMotion: boolean
  /** 進む速さ（1 がふつう） */
  speed: number
}

const DB = 'memoria-theater'
const STORE = 'music'
const KEY = 'current'
const SETTINGS_KEY = 'memoria.theater.settings'

function open(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB, 1)
    request.onupgradeneeded = () => request.result.createObjectStore(STORE)
    request.onsuccess = () => resolve(request.result)
    request.onerror = () => reject(request.error)
  })
}

async function run<T>(mode: IDBTransactionMode, work: (store: IDBObjectStore) => IDBRequest<T>): Promise<T> {
  const db = await open()
  try {
    return await new Promise<T>((resolve, reject) => {
      const tx = db.transaction(STORE, mode)
      const request = work(tx.objectStore(STORE))
      tx.oncomplete = () => resolve(request.result)
      tx.onerror = () => reject(tx.error)
      tx.onabort = () => reject(tx.error)
    })
  } finally {
    db.close()
  }
}

export async function loadMusic(): Promise<TheaterMusic | null> {
  try {
    const value = await run<TheaterMusic | undefined>('readonly', (s) => s.get(KEY) as IDBRequest<TheaterMusic | undefined>)
    return value && value.blob instanceof Blob ? value : null
  } catch {
    return null
  }
}

export async function saveMusic(music: TheaterMusic | null): Promise<void> {
  try {
    if (music) await run('readwrite', (s) => s.put(music, KEY))
    else await run('readwrite', (s) => s.delete(KEY))
  } catch {
    // 覚えられなくても、この回の再生には使える
  }
}

const DEFAULT_SETTINGS: TheaterSettings = { volume: 0.7, mediaSound: true, stopMotion: false, speed: 1 }

export function loadSettings(): TheaterSettings {
  try {
    const raw = localStorage.getItem(SETTINGS_KEY)
    if (!raw) return DEFAULT_SETTINGS
    const value = JSON.parse(raw) as Partial<TheaterSettings>
    return {
      volume: typeof value.volume === 'number' ? Math.min(1, Math.max(0, value.volume)) : DEFAULT_SETTINGS.volume,
      mediaSound: typeof value.mediaSound === 'boolean' ? value.mediaSound : DEFAULT_SETTINGS.mediaSound,
      stopMotion: typeof value.stopMotion === 'boolean' ? value.stopMotion : DEFAULT_SETTINGS.stopMotion,
      speed: typeof value.speed === 'number' && value.speed >= 0.25 && value.speed <= 4 ? value.speed : DEFAULT_SETTINGS.speed,
    }
  } catch {
    return DEFAULT_SETTINGS
  }
}

export function saveSettings(settings: TheaterSettings) {
  try {
    localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings))
  } catch {
    // 覚えられなくても動く
  }
}

/** 音源ファイルの長さ（秒）。読めなければ 0 */
export function audioDuration(blob: Blob): Promise<number> {
  return new Promise((resolve) => {
    const audio = document.createElement('audio')
    const url = URL.createObjectURL(blob)
    const done = (value: number) => {
      URL.revokeObjectURL(url)
      audio.removeAttribute('src')
      resolve(Number.isFinite(value) ? value : 0)
    }
    audio.preload = 'metadata'
    audio.onloadedmetadata = () => done(audio.duration)
    audio.onerror = () => done(0)
    audio.src = url
  })
}
