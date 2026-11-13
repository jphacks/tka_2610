// iPhone のアプリ（capture/ios。memoria を WKWebView で開く）との橋渡し。
// window.MemoriaNative と window.webkit.messageHandlers.memoria に触るのは、このファイルだけ。
// 橋渡しが無い環境（Safari・PC のブラウザ）では nativeCapture() が null を返し、画面には何も足さない。
//
// 取り決め（v1。アプリ側は capture/docs/web-bridge.md）
// - アプリが読み込み時に window.MemoriaNative = { capture: true, version: 1, sheets: [{ id, label }], heightCm: { min, max } } を入れる
// - Web は window.webkit.messageHandlers.memoria.postMessage({ type, ...項目 }) を送り、返事は postMessage の Promise で受ける
//   （WKScriptMessageHandlerWithReply。アプリがエラーの文言を返すと Promise が失敗し、その文言をそのまま画面に出す）
//   - { type: 'startCapture', kind: 'object' | 'flat', sheetId?, heightCm? } → { cancelled: true } か
//     { kind, sessionId, photoCount, mime, image }（image は base64 の JPEG）
//   - { type: 'pendingCapture' } → 渡しそびれた結果（形は startCapture と同じ）か null
//   - { type: 'artworkCreated', sessionId, artworkId, title } → 返事は見ない
//   - { type: 'openSessions' } → 返事は見ない
// - 項目名は camelCase（HTTP の API ではなく、アプリとの取り決めなので）
//
// 開発のときだけ、URL に ?fakeNative=1 を付けると偽の橋渡し（fakeBridge.ts）を使う。ブラウザで流れを確かめるため。
// ?fakeNative=cancel は撮影をやめた返事、?fakeNative=pending は渡しそびれた結果が 1 つある状態、?fakeNative=error はエラーの返事。
// 本番のビルドでは import.meta.env.DEV が false になり、偽の橋渡しはまるごと外れる。
import { fakeBridge } from './fakeBridge'

export type CaptureKind = 'object' | 'flat'

/** 平面の作品の紙（アプリの SheetPreset。label は「八つ切（27.1 × 39.2 cm）」のような表示名） */
export interface NativeSheet {
  id: string
  label: string
}

/** アプリが入れる window.MemoriaNative（読めた形） */
export interface NativeCapture {
  version: number
  sheets: NativeSheet[]
  /** 立体の作品の高さの入力で受け付ける範囲（cm） */
  heightCm: { min: number; max: number }
}

export interface CaptureRequest {
  kind: CaptureKind
  /** 平面の作品の紙（NativeSheet の id）。「わからない」なら省く */
  sheetId?: string
  /** 立体の作品の高さ（cm）。入れていなければ省く */
  heightCm?: number
}

/** 撮影の結果。file は登録に使う写真（平面はまっすぐに直した画像、立体は最初の写真） */
export interface CaptureResult {
  kind: CaptureKind
  sessionId: string
  photoCount: number
  file: File
}

export type CaptureOutcome = { cancelled: true } | ({ cancelled: false } & CaptureResult)

/** 橋渡しのエラー。message はそのまま画面に出せる文言 */
export class BridgeError extends Error {
  constructor(message: string) {
    super(message)
    this.name = 'BridgeError'
  }
}

/** アプリへ 1 つ送り、返事を受け取る */
export type BridgeTransport = (message: { type: string } & Record<string, unknown>) => Promise<unknown>

interface Bridge {
  info: unknown
  post: BridgeTransport
}

declare global {
  interface Window {
    MemoriaNative?: unknown
    webkit?: { messageHandlers?: Record<string, { postMessage?: (body: unknown) => unknown } | undefined> }
  }
}

const HEIGHT_DEFAULT = { min: 0.5, max: 300 }

const isRecord = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v)
const isFiniteNumber = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** 本物の橋渡し（アプリの中）か、開発のときの偽の橋渡し。どちらも無ければ null */
function bridge(): Bridge | null {
  if (typeof window === 'undefined') return null
  if (import.meta.env.DEV) {
    const fake = fakeBridge()
    if (fake) return fake
  }
  const handler = window.webkit?.messageHandlers?.memoria
  const postMessage = handler?.postMessage
  if (typeof postMessage !== 'function') return null
  return {
    info: window.MemoriaNative,
    post: (message) => Promise.resolve(postMessage.call(handler, message)),
  }
}

/** window.MemoriaNative を読む。形がおかしいところは既定の値にし、capture が true でなければ null */
function readInfo(raw: unknown): NativeCapture | null {
  if (!isRecord(raw) || raw.capture !== true) return null
  const version = isFiniteNumber(raw.version) ? raw.version : 1
  const sheets = Array.isArray(raw.sheets)
    ? raw.sheets.filter(
        (s): s is NativeSheet => isRecord(s) && typeof s.id === 'string' && s.id !== '' && typeof s.label === 'string' && s.label !== '',
      )
    : []
  const h = isRecord(raw.heightCm) ? raw.heightCm : {}
  const heightCm =
    isFiniteNumber(h.min) && isFiniteNumber(h.max) && h.min > 0 && h.min < h.max ? { min: h.min, max: h.max } : HEIGHT_DEFAULT
  return { version, sheets: sheets.map(({ id, label }) => ({ id, label })), heightCm }
}

/** 撮影できるアプリの中なら、その情報。無ければ null（呼ぶたびに読み直す。読み込み時には決めない） */
export function nativeCapture(): NativeCapture | null {
  const b = bridge()
  return b ? readInfo(b.info) : null
}

async function send(message: { type: string } & Record<string, unknown>): Promise<unknown> {
  const b = bridge()
  if (!b || !readInfo(b.info)) throw new BridgeError('この画面では撮影できません')
  try {
    return await b.post(message)
  } catch (e) {
    // アプリが返したエラーの文言（WebKit が Error の message に入れる）。無ければ決まった文言
    const text = e instanceof Error ? e.message.trim() : typeof e === 'string' ? e.trim() : ''
    console.warn('[MemoriaNative]', message.type, e)
    throw new BridgeError(text || 'アプリとのやりとりに失敗しました')
  }
}

const EXT: Record<string, string> = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/heic': 'heic', 'image/webp': 'webp' }

/** base64 の画像を File にする */
function imageFile(image: string, mime: string, sessionId: string): File {
  const base64 = image.replace(/^data:[^,]*,/, '').replace(/\s+/g, '')
  let binary: string
  try {
    binary = atob(base64)
  } catch {
    throw new BridgeError('撮った写真を受け取れませんでした')
  }
  if (binary.length === 0) throw new BridgeError('撮った写真を受け取れませんでした')
  const bytes = new Uint8Array(binary.length)
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i)
  const safeId = sessionId.replace(/[^A-Za-z0-9_-]/g, '').slice(0, 40) || 'capture'
  return new File([bytes], `capture-${safeId}.${EXT[mime] ?? 'jpg'}`, { type: mime, lastModified: Date.now() })
}

/** startCapture・pendingCapture の返事を読む。null は「結果なし」（pendingCapture だけが返す） */
function readOutcome(reply: unknown): CaptureOutcome | null {
  if (reply === null || reply === undefined) return null
  if (!isRecord(reply)) throw new BridgeError('アプリから思っていない返事が来ました')
  if (reply.cancelled === true) return { cancelled: true }
  const { kind, sessionId, photoCount, mime, image } = reply
  if (kind !== 'object' && kind !== 'flat') throw new BridgeError('アプリから思っていない返事が来ました（作品の種類）')
  if (typeof sessionId !== 'string' || sessionId === '') throw new BridgeError('アプリから思っていない返事が来ました（撮影の番号）')
  if (typeof image !== 'string' || image === '') throw new BridgeError('撮った写真を受け取れませんでした')
  const type = typeof mime === 'string' && mime.startsWith('image/') ? mime : 'image/jpeg'
  return {
    cancelled: false,
    kind,
    sessionId,
    photoCount: isFiniteNumber(photoCount) && photoCount >= 0 ? Math.floor(photoCount) : 1,
    file: imageFile(image, type, sessionId),
  }
}

/** ネイティブの撮影画面を開き、「これで登録」か「やめる」まで待つ */
export async function startCapture(request: CaptureRequest): Promise<CaptureOutcome> {
  const message: { type: string } & Record<string, unknown> = { type: 'startCapture', kind: request.kind }
  if (request.kind === 'flat' && request.sheetId) message.sheetId = request.sheetId
  if (request.kind === 'object' && request.heightCm !== undefined) message.heightCm = request.heightCm
  const outcome = readOutcome(await send(message))
  if (!outcome) throw new BridgeError('アプリから撮影の結果が返ってきませんでした')
  return outcome
}

let pendingInFlight: Promise<CaptureResult | null> | null = null

/** 渡しそびれた撮影の結果（撮影中に Web の画面が読み込み直されたとき）。無ければ null。
 *  同時に呼ばれたら（開発の StrictMode で 2 回呼ばれるなど）、同じ 1 回の問い合わせの結果を返す */
export function pendingCapture(): Promise<CaptureResult | null> {
  if (!pendingInFlight) {
    pendingInFlight = send({ type: 'pendingCapture' })
      .then((reply) => {
        const outcome = readOutcome(reply)
        return outcome && !outcome.cancelled ? outcome : null
      })
      .finally(() => {
        pendingInFlight = null
      })
  }
  return pendingInFlight
}

/** 作品を登録できたことを知らせる（アプリは撮影データに作品の id を書き、題名が空なら付ける） */
export async function artworkCreated(info: { sessionId: string; artworkId: string; title: string }): Promise<void> {
  await send({ type: 'artworkCreated', sessionId: info.sessionId, artworkId: info.artworkId, title: info.title })
}

/** 開発用の撮影データの画面（セッションの一覧・Mac へ送る）を開く */
export async function openSessions(): Promise<void> {
  await send({ type: 'openSessions' })
}
