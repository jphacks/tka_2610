// 作品の 3D モデル（GLB）を、写真の代わりの画像にする。登録のときに写真が無くて GLB だけを選んだときに使う
// （写真は一覧のサムネイルや詳細の画像に使うので、サーバーは写真を必須にしている）。
// 南東の斜め上から、モデル全体が収まる距離で 1 枚撮り、JPEG のファイルにする。画面には出さない描画器を使い、撮ったら捨てる。
// GLB の読み込みはアプリの 3D と同じ three-stdlib の GLTFLoader（AGENTS.md の「建物の GLB を node で読むとき」と同じ理由）
import * as THREE from 'three'
import { GLTFLoader } from 'three-stdlib'

/** 撮る画像の 1 辺（px）。サーバーが一覧用・詳細用に縮める */
const SIZE = 1024
/** 見る先からカメラへの向き（南東の斜め上） */
const DIRECTION = new THREE.Vector3(1, 0.7, 1.6).normalize()
const FOV = 30
/** モデルの外接球が画面に収まるときの余白 */
const MARGIN = 1.15
/** 背景（アプリの紙の色に近い、明るいベージュ） */
const BACKGROUND = 0xf3ece2

/** GLB のファイルを撮って、JPEG のファイルにする。読めない GLB なら reject */
export async function snapshotModel(file: File): Promise<File> {
  const url = URL.createObjectURL(file)
  const renderer = new THREE.WebGLRenderer({ antialias: true, preserveDrawingBuffer: true })
  try {
    const gltf = await new GLTFLoader().loadAsync(url)
    const scene = new THREE.Scene()
    scene.background = new THREE.Color(BACKGROUND)
    scene.add(new THREE.HemisphereLight(0xffffff, 0xd8cbb8, 2.2))
    const key = new THREE.DirectionalLight(0xffffff, 2.4)
    key.position.set(3, 5, 4)
    scene.add(key)
    scene.add(gltf.scene)

    // モデルの外接球が画面いっぱいに収まる距離から見る
    const sphere = new THREE.Box3().setFromObject(gltf.scene).getBoundingSphere(new THREE.Sphere())
    const radius = Math.max(sphere.radius, 1e-3)
    const distance = (radius * MARGIN) / Math.sin(THREE.MathUtils.degToRad(FOV / 2))
    const camera = new THREE.PerspectiveCamera(FOV, 1, distance / 100, distance * 10)
    camera.position.copy(sphere.center).addScaledVector(DIRECTION, distance)
    camera.lookAt(sphere.center)

    renderer.setSize(SIZE, SIZE, false)
    renderer.outputColorSpace = THREE.SRGBColorSpace
    renderer.toneMapping = THREE.ACESFilmicToneMapping
    renderer.render(scene, camera)

    const blob = await new Promise<Blob | null>((resolve) => renderer.domElement.toBlob(resolve, 'image/jpeg', 0.9))
    if (!blob) throw new Error('3Dモデルを画像にできませんでした')
    const name = file.name.replace(/\.glb$/i, '') || 'model'
    return new File([blob], `${name}.jpg`, { type: 'image/jpeg' })
  } finally {
    URL.revokeObjectURL(url)
    renderer.dispose()
    renderer.forceContextLoss()
  }
}
