// 作品の GLB の読み込みと、メモリの後かたづけ（FittedModel が使う。家具と建物は models.tsx の useGLTF のまま）。
//
// 作品の GLB はテクスチャが多い（サンプルの作品は 1 点で 20〜30 枚。ほとんどが 768px）。
// GPU に送ると 1 枚 3 MB ほど（RGBA・ミップマップ込み）になり、おへやに 10 点並ぶと 300〜500 MB になって、
// スマホのブラウザが落ちる（本番で測った値。ホームの画面だけで約 740 MB、そのうち作品が約 470 MB）。
// そこで、
//   1. maxTexture を渡した画面（おへや・ホーム・模様替え・鑑賞モード）では、読み込んだ直後にテクスチャを縮める。
//      作品は画面の中で小さいので 256px で足りる（近くで見たいときは作品の詳細を開く）。元の画像は捨てる。
//      作品の詳細（maxTexture なし）は、今までどおり元の大きさのまま
//   2. 使っている画面の数を数え、どの画面も使わなくなって RELEASE_MS たったら、GPU と JS の両方からメモリを返す
//      （drei の useGLTF は読んだ GLB を覚えたまま捨てないので、見て回るほどメモリが増え続けていた）
// 同じ GLB でも、縮める大きさが違えば別のものとして持つ（作品の詳細とおへやで、テクスチャを共有しない）。

import { useEffect } from 'react'
import { GLTFLoader } from 'three-stdlib'
import * as THREE from 'three'

/** どの画面も使わなくなってから、メモリを返すまでの時間（ms）。画面を行き来するあいだは、読み直さずに使い回す */
const RELEASE_MS = 20_000

interface Entry {
  promise: Promise<THREE.Object3D>
  scene: THREE.Object3D | null
  /** 読めなかったときのエラー（ErrorBoundary へ投げる。捨てるまでは覚えておき、同じ画面で読み直し続けないようにする） */
  error: unknown
  refs: number
  timer: number
}

const cache = new Map<string, Entry>()
const loader = new GLTFLoader()

const keyOf = (url: string, maxTexture: number) => `${maxTexture}|${url}`

function scheduleRelease(key: string, entry: Entry) {
  window.clearTimeout(entry.timer)
  entry.timer = window.setTimeout(() => {
    if (entry.refs > 0 || cache.get(key) !== entry) return
    // 読み込み中は待つ（読み終わってから捨てないと、読んだものが GPU に残る）
    if (!entry.scene && !entry.error) { scheduleRelease(key, entry); return }
    cache.delete(key)
    if (entry.scene) disposeScene(entry.scene)
  }, RELEASE_MS)
}

/** 作品の GLB を読む（maxTexture > 0 なら、テクスチャをその大きさまで縮める）。先読みにも使う */
export function loadArtModel(url: string, maxTexture = 0): Promise<THREE.Object3D> {
  const key = keyOf(url, maxTexture)
  let entry = cache.get(key)
  if (!entry) {
    const created: Entry = { promise: Promise.resolve(null as unknown as THREE.Object3D), scene: null, error: null, refs: 0, timer: 0 }
    created.promise = loader.loadAsync(url).then(async (gltf) => {
      if (maxTexture > 0) await shrinkTextures(gltf.scene, maxTexture)
      created.scene = gltf.scene
      return gltf.scene
    })
    // 読めなかったときは、捨てるまでエラーを覚えておく（捨てたあとに開き直せば、読み直す）
    created.promise.catch((error) => { created.error = error ?? new Error(`failed to load ${url}`) })
    entry = created
    cache.set(key, entry)
    // 先読みだけで、どの画面も使わなかったときも捨てる
    scheduleRelease(key, entry)
  }
  return entry.promise
}

/**
 * 作品の GLB を読み、この部品が画面にあるあいだは捨てない。読み込み中は Suspense で待ち、読めなければ ErrorBoundary へ投げる。
 * 読み終わっていれば、その場で返す（React の use() は、読み終わった Promise でも 1 度待たせて、作品が一瞬消えるので使わない）
 */
export function useArtModel(url: string, maxTexture = 0): THREE.Object3D {
  const key = keyOf(url, maxTexture)
  const promise = loadArtModel(url, maxTexture)
  const entry = cache.get(key)
  if (entry?.error) throw entry.error
  if (!entry?.scene) throw promise
  useEffect(() => {
    const entry = cache.get(key)
    if (!entry) return
    entry.refs++
    window.clearTimeout(entry.timer)
    return () => {
      entry.refs--
      if (entry.refs <= 0) scheduleRelease(key, entry)
    }
  }, [key])
  return entry.scene
}

type ResizableImage = ImageBitmap | HTMLImageElement | HTMLCanvasElement

/** 場面の材質が使っているテクスチャを、長い辺が max 以下になるよう縮める（元の画像は捨てる） */
async function shrinkTextures(scene: THREE.Object3D, max: number) {
  const resized = new Map<ResizableImage, Promise<ResizableImage>>()
  const jobs: Promise<void>[] = []
  for (const texture of texturesOf(scene)) {
    const image = texture.image as ResizableImage | undefined
    if (!image || !(image.width > 0) || Math.max(image.width, image.height) <= max) continue
    let job = resized.get(image)
    if (!job) {
      job = resizeImage(image, max)
      resized.set(image, job)
    }
    jobs.push(job.then((small) => {
      texture.image = small
      texture.needsUpdate = true
    }))
  }
  await Promise.all(jobs)
  for (const image of resized.keys()) if (image instanceof ImageBitmap) image.close()
}

async function resizeImage(image: ResizableImage, max: number): Promise<ResizableImage> {
  const scale = max / Math.max(image.width, image.height)
  const width = Math.max(1, Math.round(image.width * scale))
  const height = Math.max(1, Math.round(image.height * scale))
  // ImageBitmap（Chrome・Android）は、ブラウザに縮めてもらう（メインスレッドを使わない）
  if (typeof createImageBitmap === 'function' && image instanceof ImageBitmap) {
    try {
      const small = await createImageBitmap(image, {
        resizeWidth: width,
        resizeHeight: height,
        resizeQuality: 'high',
        premultiplyAlpha: 'none',
        colorSpaceConversion: 'none',
      })
      if (small.width === width && small.height === height) return small
      small.close()
    } catch {
      // 縮める指定に対応していないブラウザは、下の canvas で縮める
    }
  }
  // HTMLImageElement（iPhone の Safari。three の GLTFLoader は Safari では ImageBitmap を使わない）は canvas に描いて縮める
  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height
  const ctx = canvas.getContext('2d')
  if (!ctx) return image
  ctx.imageSmoothingQuality = 'high'
  ctx.drawImage(image, 0, 0, width, height)
  return canvas
}

function texturesOf(scene: THREE.Object3D): Set<THREE.Texture> {
  const found = new Set<THREE.Texture>()
  scene.traverse((object) => {
    const material = (object as THREE.Mesh).material as THREE.Material | THREE.Material[] | undefined
    if (!material) return
    for (const m of Array.isArray(material) ? material : [material]) {
      for (const value of Object.values(m)) if (value instanceof THREE.Texture) found.add(value)
    }
  })
  return found
}

/** GPU（テクスチャ・形・材質）と JS（画像）の両方からメモリを返す */
function disposeScene(scene: THREE.Object3D) {
  const materials = new Set<THREE.Material>()
  scene.traverse((object) => {
    const mesh = object as THREE.Mesh
    if (mesh.geometry) mesh.geometry.dispose()
    const material = mesh.material as THREE.Material | THREE.Material[] | undefined
    if (material) for (const m of Array.isArray(material) ? material : [material]) materials.add(m)
  })
  for (const texture of texturesOf(scene)) {
    texture.dispose()
    const image = texture.image as unknown
    if (image instanceof ImageBitmap) image.close()
  }
  materials.forEach((m) => m.dispose())
}
