// 写真の「向きをなおす・切り取る」の計算（ブラウザの中だけで処理する。サーバーには送らない）。
// スマホの写真に付いている向きの情報（EXIF）は、createImageBitmap が反映して読む。出力の JPEG には向きの情報を付けないので、二重に回ることはない。
// 画面は PhotoEditor.tsx。ArtworkForm の「向きをなおす・切り取る」から使う。
 
/** 処理する大きさ（長い辺）。大きい写真は、この大きさに縮めてから扱う */
const WORK_MAX = 2400
 
/** 切り取る範囲。写真全体を 0〜1 とした割合（左・上・右・下） */
export interface CropRect {
  l: number
  t: number
  r: number
  b: number
}
 
export const FULL_RECT: CropRect = { l: 0, t: 0, r: 1, b: 1 }
 
function makeCanvas(w: number, h: number): HTMLCanvasElement {
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(w))
  canvas.height = Math.max(1, Math.round(h))
  return canvas
}
 
/** 写真を読んで、長い辺が WORK_MAX 以下のキャンバスにする。読めないときは例外を投げる */
export async function loadWork(file: Blob): Promise<HTMLCanvasElement> {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, WORK_MAX / Math.max(bitmap.width, bitmap.height))
  const canvas = makeCanvas(bitmap.width * scale, bitmap.height * scale)
  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('この端末では、写真を編集できません')
  ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height)
  bitmap.close()
  return canvas
}
 
/** 時計回りに quarter × 90° 回したキャンバス（quarter は整数。負でもよい） */
export function rotateCanvas(src: HTMLCanvasElement, quarter: number): HTMLCanvasElement {
  const q = ((quarter % 4) + 4) % 4
  if (q === 0) return src
  const swap = q % 2 === 1
  const out = makeCanvas(swap ? src.height : src.width, swap ? src.width : src.height)
  const ctx = out.getContext('2d')
  if (!ctx) throw new Error('この端末では、写真を編集できません')
  ctx.translate(out.width / 2, out.height / 2)
  ctx.rotate((q * Math.PI) / 2)
  ctx.drawImage(src, -src.width / 2, -src.height / 2)
  return out
}
 
/** 画面に出す用に、長い辺が max 以下のキャンバスに縮める */
export function shrinkCanvas(src: HTMLCanvasElement, max: number): HTMLCanvasElement {
  const scale = Math.min(1, max / Math.max(src.width, src.height))
  if (scale === 1) return src
  const out = makeCanvas(src.width * scale, src.height * scale)
  const ctx = out.getContext('2d')
  if (!ctx) throw new Error('この端末では、写真を編集できません')
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(src, 0, 0, out.width, out.height)
  return out
}
 
/** 範囲が写真全体か */
export function isFull(rect: CropRect): boolean {
  return rect.l <= 0.001 && rect.t <= 0.001 && rect.r >= 0.999 && rect.b >= 0.999
}
 
/** キャンバスの rect の部分を JPEG の File にする。作れないときは例外を投げる */
export async function cropToFile(src: HTMLCanvasElement, rect: CropRect, baseName = 'photo'): Promise<File> {
  const sx = Math.round(rect.l * src.width)
  const sy = Math.round(rect.t * src.height)
  const sw = Math.max(1, Math.round((rect.r - rect.l) * src.width))
  const sh = Math.max(1, Math.round((rect.b - rect.t) * src.height))
  const out = makeCanvas(sw, sh)
  const ctx = out.getContext('2d')
  if (!ctx) throw new Error('この端末では、写真を編集できません')
  ctx.drawImage(src, sx, sy, sw, sh, 0, 0, sw, sh)
  const blob = await new Promise<Blob | null>((resolve) => out.toBlob(resolve, 'image/jpeg', 0.92))
  if (!blob) throw new Error('写真を作れませんでした')
  return new File([blob], `${baseName}.jpg`, { type: 'image/jpeg' })
}