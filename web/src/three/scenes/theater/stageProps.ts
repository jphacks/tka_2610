// シアターの舞台の小物（家・木・低木・丘）を、手描きの絵を貼った厚みのある板として作る。
// 絵と輪郭は tools/digest-stage/generate_stage_textures.py が作り、/stage-assets/stage.json に輪郭（0〜1 の多角形）・
// 大きさ・厚み・裏と縁の色が入っている。ここではその輪郭を押し出して（ExtrudeGeometry）、表に絵、裏と縁に紙の色を付ける。
// 同じ種類の小物はジオメトリと材質を使い回す（dispose はシーンを閉じるときに 1 回）。
import * as THREE from 'three'

export const STAGE_BASE = '/stage-assets/'

export type PropKind = 'house' | 'tree' | 'shrub' | 'hill'

export interface StageProp {
  name: string
  kind: PropKind
  texture: string
  width: number
  height: number
  depth: number
  back: string
  edge: string
  outline: [number, number][]
}

export interface StageManifest {
  version: number
  ground: string
  sky: string
  paint_normal: string
  props: StageProp[]
}

let manifestPromise: Promise<StageManifest> | null = null
/** stage.json を 1 回だけ読む */
export function loadStageManifest(): Promise<StageManifest> {
  manifestPromise ??= fetch(`${STAGE_BASE}stage.json`).then((r) => {
    if (!r.ok) throw new Error(`stage.json を読み込めませんでした (${r.status})`)
    return r.json() as Promise<StageManifest>
  })
  manifestPromise.catch(() => { manifestPromise = null })
  return manifestPromise
}

/**
 * 輪郭を押し出した板。表（+Z 向き）・裏・縁の 3 つの材質の組（group 0・1・2）に分け、
 * 表と裏の UV は輪郭の外枠に合わせて貼り直す（u = x / 幅 + 0.5、v = y / 高さ）。底辺の中心が原点
 */
export function cardGeometry(prop: StageProp): THREE.BufferGeometry {
  const { width: w, height: h, depth } = prop
  const shape = new THREE.Shape(prop.outline.map(([x, y]) => new THREE.Vector2((x - 0.5) * w, y * h)))
  const bevel = Math.min(0.03, depth * 0.2)
  const extruded = new THREE.ExtrudeGeometry(shape, {
    depth: depth - bevel * 2,
    bevelEnabled: true,
    bevelThickness: bevel,
    bevelSize: bevel * 0.8,
    bevelOffset: -bevel * 0.8,
    bevelSegments: 2,
    curveSegments: 4,
  })
  extruded.translate(0, 0, -(depth - bevel * 2) / 2)
  const source = extruded.index ? extruded.toNonIndexed() : extruded
  const pos = source.getAttribute('position')
  const nor = source.getAttribute('normal')
  const triangles = pos.count / 3
  const buckets: number[][] = [[], [], []]
  for (let t = 0; t < triangles; t++) {
    const nz = (nor.getZ(t * 3) + nor.getZ(t * 3 + 1) + nor.getZ(t * 3 + 2)) / 3
    buckets[nz > 0.7 ? 0 : nz < -0.7 ? 1 : 2].push(t)
  }
  const order = buckets.flat()
  const positions = new Float32Array(order.length * 9)
  const normals = new Float32Array(order.length * 9)
  const uvs = new Float32Array(order.length * 6)
  order.forEach((t, i) => {
    for (let k = 0; k < 3; k++) {
      const v = t * 3 + k
      const x = pos.getX(v)
      const y = pos.getY(v)
      positions.set([x, y, pos.getZ(v)], (i * 3 + k) * 3)
      normals.set([nor.getX(v), nor.getY(v), nor.getZ(v)], (i * 3 + k) * 3)
      uvs.set([x / w + 0.5, y / h], (i * 3 + k) * 2)
    }
  })
  const geometry = new THREE.BufferGeometry()
  geometry.setAttribute('position', new THREE.BufferAttribute(positions, 3))
  geometry.setAttribute('normal', new THREE.BufferAttribute(normals, 3))
  geometry.setAttribute('uv', new THREE.BufferAttribute(uvs, 2))
  let start = 0
  buckets.forEach((bucket, group) => {
    geometry.addGroup(start * 3, bucket.length * 3, group)
    start += bucket.length
  })
  geometry.computeBoundingSphere()
  extruded.dispose()
  if (source !== extruded) source.dispose()
  return geometry
}

/** 舞台で使うテクスチャと材質の置き場。close() でまとめて片付ける */
export class StageKit {
  readonly manifest: StageManifest
  readonly paintNormal: THREE.Texture
  private readonly loader = new THREE.TextureLoader()
  private readonly textures: THREE.Texture[] = []
  private readonly geometries = new Map<string, THREE.BufferGeometry>()
  private readonly materials = new Map<string, THREE.Material[]>()
  private readonly anisotropy: number

  constructor(manifest: StageManifest, anisotropy: number, onLoad: () => void) {
    this.manifest = manifest
    this.anisotropy = Math.min(8, anisotropy)
    this.onLoad = onLoad
    this.paintNormal = this.texture(manifest.paint_normal, false)
    this.paintNormal.wrapS = this.paintNormal.wrapT = THREE.RepeatWrapping
  }

  private readonly onLoad: () => void

  texture(path: string, color = true): THREE.Texture {
    const texture = this.loader.load(`${STAGE_BASE}${path}`, this.onLoad)
    texture.colorSpace = color ? THREE.SRGBColorSpace : THREE.NoColorSpace
    texture.anisotropy = this.anisotropy
    this.textures.push(texture)
    return texture
  }

  geometry(prop: StageProp): THREE.BufferGeometry {
    let geometry = this.geometries.get(prop.name)
    if (!geometry) {
      geometry = cardGeometry(prop)
      this.geometries.set(prop.name, geometry)
    }
    return geometry
  }

  /** 表（絵）・裏・縁の材質。紙の凹凸を少しだけ付ける */
  material(prop: StageProp): THREE.Material[] {
    let list = this.materials.get(prop.name)
    if (!list) {
      const map = this.texture(prop.texture)
      map.wrapS = map.wrapT = THREE.ClampToEdgeWrapping
      const front = new THREE.MeshStandardMaterial({ map, normalMap: this.paintNormal, normalScale: new THREE.Vector2(0.45, 0.45), roughness: 0.9, metalness: 0 })
      const back = new THREE.MeshStandardMaterial({ color: prop.back, normalMap: this.paintNormal, normalScale: new THREE.Vector2(0.3, 0.3), roughness: 0.95, metalness: 0 })
      const edge = new THREE.MeshStandardMaterial({ color: prop.edge, roughness: 0.92, metalness: 0 })
      list = [front, back, edge]
      this.materials.set(prop.name, list)
    }
    return list
  }

  /** 小物 1 つ（Mesh）。geometry と material は共有 */
  mesh(prop: StageProp, shadows: boolean): THREE.Mesh {
    const mesh = new THREE.Mesh(this.geometry(prop), this.material(prop))
    mesh.castShadow = shadows
    mesh.receiveShadow = shadows
    mesh.name = `STAGE_${prop.name}`
    return mesh
  }

  close() {
    this.textures.forEach((t) => t.dispose())
    this.geometries.forEach((g) => g.dispose())
    this.materials.forEach((list) => list.forEach((m) => m.dispose()))
  }
}

/** シードで決まる乱数（場面ごとの家や木の並びを、毎回同じにする） */
export function seeded(seed: number) {
  let s = seed >>> 0 || 1
  return () => {
    s ^= s << 13
    s ^= s >>> 17
    s ^= s << 5
    return ((s >>> 0) % 100000) / 100000
  }
}
