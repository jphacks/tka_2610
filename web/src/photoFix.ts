// 絵の写真の「影をとる」補正（ブラウザの中だけで処理する。サーバーには送らない）。
// 紙の明るさのムラ（影）を推定して、暗いところだけ持ち上げ、全体の明るさをそろえる。絵の線や色は、なるべくそのまま残す。
// 使うのは作品の種類が「絵画」のときだけ（ArtworkForm）。立体の工作は、影も形の一部なので対象にしない。
 
/** 処理する大きさ（長い辺）。大きい写真は、この大きさに縮めてから処理する */
const WORK_MAX = 2400
/** 明るさの地図の大きさ（長い辺）。小さいほど、ゆるやかな影だけを見る */
const MAP_MAX = 96
/** 暗いところを明るくする倍率の上限。大きくすると、色のこい絵まで白っぽくなる */
const MAX_GAIN = 2.2
/** 紙の白さをここまで持ち上げる（0〜255）。写真全体が暗いときの下げ止まり */
const PAPER_WHITE = 245
 
/** 周りの半径 r の四角の中の、いちばん明るい値（暗い線を消して、紙の明るさだけを残す） */
function maxFilter(src: Float32Array, w: number, h: number, r: number): Float32Array {
  const tmp = new Float32Array(src.length)
  const out = new Float32Array(src.length)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let m = 0
      for (let k = Math.max(0, x - r); k <= Math.min(w - 1, x + r); k++) m = Math.max(m, src[y * w + k])
      tmp[y * w + x] = m
    }
  }
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let m = 0
      for (let k = Math.max(0, y - r); k <= Math.min(h - 1, y + r); k++) m = Math.max(m, tmp[k * w + x])
      out[y * w + x] = m
    }
  }
  return out
}
 
/** 周りの半径 r の四角の平均（ぼかす）。ふちは、あるところだけで平均する */
function boxBlur(src: Float32Array, w: number, h: number, r: number): Float32Array {
  const tmp = new Float32Array(src.length)
  const out = new Float32Array(src.length)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let sum = 0
      let n = 0
      for (let k = Math.max(0, x - r); k <= Math.min(w - 1, x + r); k++) {
        sum += src[y * w + k]
        n++
      }
      tmp[y * w + x] = sum / n
    }
  }
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let sum = 0
      let n = 0
      for (let k = Math.max(0, y - r); k <= Math.min(h - 1, y + r); k++) {
        sum += tmp[k * w + x]
        n++
      }
      out[y * w + x] = sum / n
    }
  }
  return out
}
 
/** 絵の写真から影をならした写真（JPEG）を作る。読めない・作れないときは例外を投げる */
export async function removeShadow(file: Blob, baseName = 'photo'): Promise<File> {
  const bitmap = await createImageBitmap(file)
  const scale = Math.min(1, WORK_MAX / Math.max(bitmap.width, bitmap.height))
  const w = Math.max(1, Math.round(bitmap.width * scale))
  const h = Math.max(1, Math.round(bitmap.height * scale))
 
  const canvas = document.createElement('canvas')
  canvas.width = w
  canvas.height = h
  const ctx = canvas.getContext('2d', { willReadFrequently: true })
  if (!ctx) throw new Error('この端末では、写真を補正できません')
  ctx.drawImage(bitmap, 0, 0, w, h)
  bitmap.close()
  const image = ctx.getImageData(0, 0, w, h)
  const px = image.data
 
  // 1. 明るさの地図：小さい絵にして、暗い線を消して（maxFilter）、なめらかにする（boxBlur）
  const ratio = MAP_MAX / Math.max(w, h)
  const mw = Math.max(2, Math.round(w * ratio))
  const mh = Math.max(2, Math.round(h * ratio))
  const small = document.createElement('canvas')
  small.width = mw
  small.height = mh
  const sctx = small.getContext('2d', { willReadFrequently: true })
  if (!sctx) throw new Error('この端末では、写真を補正できません')
  sctx.imageSmoothingQuality = 'high'
  sctx.drawImage(canvas, 0, 0, mw, mh)
  const sp = sctx.getImageData(0, 0, mw, mh).data
  const lum = new Float32Array(mw * mh)
  for (let i = 0; i < lum.length; i++) lum[i] = 0.299 * sp[i * 4] + 0.587 * sp[i * 4 + 1] + 0.114 * sp[i * 4 + 2]
  const paper = boxBlur(boxBlur(maxFilter(lum, mw, mh, 6), mw, mh, 4), mw, mh, 4)
 
  // 2. いちばん明るい紙（上位 5% のあたり）を基準にして、暗いところの持ち上げ方（倍率）を決める
  const sorted = Float32Array.from(paper).sort()
  const target = Math.max(1, sorted[Math.floor(sorted.length * 0.95)])
  const gain = new Float32Array(paper.length)
  for (let i = 0; i < gain.length; i++) gain[i] = Math.min(MAX_GAIN, Math.max(1, target / Math.max(paper[i], 1)))
  // 全体が暗い写真は、紙の白さまで少しだけ持ち上げる
  const whiten = Math.min(1.25, Math.max(1, PAPER_WHITE / target))
 
  // 3. 元の大きさの写真に、倍率をなめらかにかける（倍率の地図は、写真の大きさに引き伸ばして使う）
  for (let y = 0; y < h; y++) {
    const fy = Math.min(mh - 1, Math.max(0, ((y + 0.5) * mh) / h - 0.5))
    const y0 = Math.floor(fy)
    const y1 = Math.min(mh - 1, y0 + 1)
    const ty = fy - y0
    for (let x = 0; x < w; x++) {
      const fx = Math.min(mw - 1, Math.max(0, ((x + 0.5) * mw) / w - 0.5))
      const x0 = Math.floor(fx)
      const x1 = Math.min(mw - 1, x0 + 1)
      const tx = fx - x0
      const top = gain[y0 * mw + x0] * (1 - tx) + gain[y0 * mw + x1] * tx
      const bottom = gain[y1 * mw + x0] * (1 - tx) + gain[y1 * mw + x1] * tx
      const k = (top * (1 - ty) + bottom * ty) * whiten
      const o = (y * w + x) * 4
      px[o] = Math.min(255, px[o] * k)
      px[o + 1] = Math.min(255, px[o + 1] * k)
      px[o + 2] = Math.min(255, px[o + 2] * k)
    }
  }
  ctx.putImageData(image, 0, 0)
 
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/jpeg', 0.92))
  if (!blob) throw new Error('補正した写真を作れませんでした')
  return new File([blob], `${baseName}.jpg`, { type: 'image/jpeg' })
}