// 作品の写真の背景の明るさを、作品ごとにそろえる（作品一覧。Img の evenTone）。
//
// 写真は撮ったときの光で、背景の灰色の明るさが作品ごとに違う（サンプルでは 184〜221）。
// 読み込んだ写真のふち（背景が写っている所）を小さく描いて明るさを測り、
// 背景が TARGET の明るさになるように、作品ごとの brightness の倍率を決める（CSS の --tone）。
// 測れない写真（ふちの色がばらばら・はっきりした色）は 1（そのまま）。補正は MIN〜MAX 倍まで。
// 同じ画像は測った結果を覚えておく（一覧を開き直すたびに測らない）。

/** そろえる背景の明るさ（0〜255） */
const TARGET = 236
const MIN = 0.9
const MAX = 1.3
/** 測るときに縮める大きさ（px）と、ふちとして見る幅（px） */
const SIZE = 48
const EDGE = 3
/** ふちの明るさのばらつき（四分位の幅）がこれより大きければ、無地の背景ではないとみなす */
const MAX_SPREAD = 22
/** ふちの色の鮮やかさ（RGB の最大−最小の真ん中の値）がこれより大きければ、灰色の背景ではないとみなす */
const MAX_CHROMA = 30

const cache = new Map<string, number>()

/** その写真の明るさの倍率（読み込み済みの img を渡す）。測れなければ 1 */
export function photoTone(img: HTMLImageElement): number {
  const key = img.currentSrc || img.src
  const known = cache.get(key)
  if (known !== undefined) return known
  const tone = measure(img)
  cache.set(key, tone)
  return tone
}

function measure(img: HTMLImageElement): number {
  if (!img.naturalWidth || !img.naturalHeight) return 1
  try {
    const canvas = document.createElement('canvas')
    canvas.width = SIZE
    canvas.height = SIZE
    const ctx = canvas.getContext('2d', { willReadFrequently: true })
    if (!ctx) return 1
    ctx.drawImage(img, 0, 0, SIZE, SIZE)
    const { data } = ctx.getImageData(0, 0, SIZE, SIZE)
    const lums: number[] = []
    const chromas: number[] = []
    for (let y = 0; y < SIZE; y++) {
      for (let x = 0; x < SIZE; x++) {
        if (x >= EDGE && x < SIZE - EDGE && y >= EDGE && y < SIZE - EDGE) continue
        const i = (y * SIZE + x) * 4
        const r = data[i], g = data[i + 1], b = data[i + 2]
        lums.push(0.299 * r + 0.587 * g + 0.114 * b)
        chromas.push(Math.max(r, g, b) - Math.min(r, g, b))
      }
    }
    lums.sort((a, b) => a - b)
    chromas.sort((a, b) => a - b)
    const at = (list: number[], q: number) => list[Math.floor((list.length - 1) * q)]
    const background = at(lums, 0.5)
    if (at(lums, 0.75) - at(lums, 0.25) > MAX_SPREAD) return 1
    if (at(chromas, 0.5) > MAX_CHROMA) return 1
    if (!(background > 0)) return 1
    return Math.min(MAX, Math.max(MIN, TARGET / background))
  } catch {
    // 別のサイトの画像など、読めないときはそのまま
    return 1
  }
}
