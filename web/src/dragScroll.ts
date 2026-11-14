// 横に流れる列（data-drag-scroll を付けた要素）を、PC のマウスでつかんで動かせるようにする。main.tsx で 1 回だけ installDragScroll() を呼ぶ。
//
// 指（タッチ）とトラックパッドは、ブラウザがもともと横にスクロールできるので何もしない。マウスの左ボタンだけを扱う。
//   押して DRAG_START_PX より動かす … つかんだ。列が指の動きにぴったり付いてくる（そのあいだは scroll-snap を止める）
//   離す                         … 動かしていた速さのぶん、すっと流れて止まる。列に scroll-snap があれば、止まる位置を項目にそろえる
//   動かさずに離す                 … ふつうのクリック（ボタンを押せる）
// つかんで動かしたあとのクリックは捨てる（離したところのボタンが押されないように）。画像のドラッグ（ブラウザ標準）と文字の選択も止める。
// 入力欄・スライダー（input・textarea・select）・音声や動画の再生バー（audio・video）と、data-no-drag-scroll の中では始めない。

/** これより動かしたら、クリックではなく「つかんで動かす」にする（px） */
const DRAG_START_PX = 6
/** 離したときの速さ（px/ms）に掛けて、どれだけ先まで流すか（ms）。大きいほど遠くまで流れる */
const FLING_MS = 260
/** 速さを測るのに使う、離す直前の動きの長さ（ms） */
const VELOCITY_WINDOW_MS = 90

interface Sample {
  x: number
  t: number
}

/** 列の中で、項目に合わせて止まれる位置（scroll-snap-align のある子のもの）。scroll-snap の無い列は空 */
function snapPoints(el: HTMLElement): number[] {
  if (getComputedStyle(el).scrollSnapType.startsWith('none')) return []
  const box = el.getBoundingClientRect()
  const style = getComputedStyle(el)
  const padStart = parseFloat(style.scrollPaddingLeft) || 0
  const padEnd = parseFloat(style.scrollPaddingRight) || 0
  const points: number[] = []
  for (const child of Array.from(el.children) as HTMLElement[]) {
    const align = getComputedStyle(child).scrollSnapAlign.split(' ').pop()
    if (!align || align === 'none') continue
    const rect = child.getBoundingClientRect()
    const left = rect.left - box.left + el.scrollLeft
    if (align === 'start') points.push(left - padStart)
    else if (align === 'end') points.push(left + rect.width - el.clientWidth + padEnd)
    else points.push(left + rect.width / 2 - el.clientWidth / 2)
  }
  return points
}

/** 流れて止まる位置。項目に合わせるときは、いちばん近い項目の位置にする */
function restingPlace(el: HTMLElement, target: number): number {
  const max = el.scrollWidth - el.clientWidth
  const clamp = (v: number) => Math.min(max, Math.max(0, v))
  const points = snapPoints(el)
  if (points.length === 0) return clamp(target)
  let best = points[0]
  for (const p of points) if (Math.abs(p - target) < Math.abs(best - target)) best = p
  return clamp(best)
}

/** 動かしたあとに 1 回だけ来るクリックを捨てる */
function swallowNextClick(el: HTMLElement) {
  const swallow = (e: MouseEvent) => {
    e.preventDefault()
    e.stopPropagation()
  }
  el.addEventListener('click', swallow, { capture: true, once: true })
  // クリックが来なかった（列の外で離した）ときに、次のふつうのクリックまで捨てないよう、少ししたら外す
  window.setTimeout(() => el.removeEventListener('click', swallow, { capture: true }), 0)
}

function startDrag(el: HTMLElement, down: PointerEvent) {
  const startX = down.clientX
  const startLeft = el.scrollLeft
  const samples: Sample[] = [{ x: down.clientX, t: down.timeStamp }]
  let dragging = false

  const onMove = (e: PointerEvent) => {
    const dx = e.clientX - startX
    if (!dragging) {
      if (Math.abs(dx) < DRAG_START_PX) return
      dragging = true
      // 指に付いてくるあいだは、項目に吸い付かせない・すべらせない
      el.style.scrollSnapType = 'none'
      el.style.scrollBehavior = 'auto'
      el.classList.add('is-drag-scrolling')
      document.documentElement.classList.add('is-drag-scrolling-page')
    }
    e.preventDefault()
    el.scrollLeft = startLeft - dx
    samples.push({ x: e.clientX, t: e.timeStamp })
    while (samples.length > 2 && e.timeStamp - samples[0].t > VELOCITY_WINDOW_MS) samples.shift()
  }

  const finish = (e: PointerEvent) => {
    window.removeEventListener('pointermove', onMove)
    window.removeEventListener('pointerup', finish)
    window.removeEventListener('pointercancel', finish)
    if (!dragging) return
    el.classList.remove('is-drag-scrolling')
    document.documentElement.classList.remove('is-drag-scrolling-page')
    if (e.type === 'pointerup') swallowNextClick(el)

    // 離す直前の速さ（px/ms。右へ動かすと列は左へ戻るので、向きを逆にする）
    const first = samples[0]
    const last = samples[samples.length - 1]
    const dt = last.t - first.t
    const velocity = dt > 0 && e.timeStamp - last.t < 60 ? (last.x - first.x) / dt : 0
    const reduce = window.matchMedia('(prefers-reduced-motion: reduce)').matches
    const target = restingPlace(el, el.scrollLeft - velocity * (reduce ? 0 : FLING_MS))

    const restore = () => {
      el.style.scrollSnapType = ''
      el.style.scrollBehavior = ''
    }
    if (Math.abs(target - el.scrollLeft) < 1) {
      restore()
      return
    }
    el.scrollTo({ left: target, behavior: reduce ? 'auto' : 'smooth' })
    // 止まった位置は項目の位置なので、scroll-snap を戻しても動かない。scrollend の無いブラウザのために時間でも戻す
    let restored = false
    const done = () => {
      if (restored) return
      restored = true
      el.removeEventListener('scrollend', done)
      restore()
    }
    el.addEventListener('scrollend', done)
    window.setTimeout(done, 900)
  }

  window.addEventListener('pointermove', onMove, { passive: false })
  window.addEventListener('pointerup', finish)
  window.addEventListener('pointercancel', finish)
}

let installed = false

export function installDragScroll() {
  if (installed) return
  installed = true
  document.addEventListener('pointerdown', (e) => {
    if (e.pointerType !== 'mouse' || e.button !== 0 || e.defaultPrevented) return
    const target = e.target as Element | null
    const el = target?.closest<HTMLElement>('[data-drag-scroll]')
    if (!el || el.scrollWidth <= el.clientWidth + 1) return
    if (target?.closest('input, textarea, select, audio, video, [contenteditable="true"], [data-no-drag-scroll]')) return
    startDrag(el, e)
  })
  // 列の中の画像や、リンクのブラウザ標準のドラッグ（ゴーストの画像が出る）を止める
  document.addEventListener('dragstart', (e) => {
    if ((e.target as Element | null)?.closest?.('[data-drag-scroll]')) e.preventDefault()
  })
}
