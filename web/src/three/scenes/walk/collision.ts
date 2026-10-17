// ステージ（家の建物と家具）の形から、歩くときの当たり判定を作る。家具を置き直したら作り直す（WalkScene）。
// 壁・床・家具などは、見えている形そのものに当たる。Unity のような見えない壁は作らない。
// 作品・天井や、上を歩ける敷物（ラグ）は、stagePreset.ts の collisionIgnore で外す。
//
// 三角形は 1m 角の格子に振り分けておき、体の周りの格子にある三角形だけを調べる。
// three.js の Octree は、床のような大きな三角形を細かい箱すべてに複製するため、
// 大きなステージ（以前の博物館は約 9 万三角形）では作るのに数秒かかる。格子なら 0.1 秒ほどで作れる。
// 三角形と体（カプセル）の判定そのものは Octree のものを使う。

import * as THREE from 'three'
import { Capsule } from 'three/addons/math/Capsule.js'
import { Octree } from 'three/addons/math/Octree.js'

export interface CollisionFilter {
  /** 名前がこれで始まるノード（とその子）を外す */
  prefixes: string[]
  /** 名前にこれを含むノード（とその子）を外す */
  contains: string[]
}

export interface CollisionHit {
  /** 押し戻す向き */
  normal: THREE.Vector3
  /** 押し戻す距離（m） */
  depth: number
}

/** 歩く人（player.ts）が使う当たり判定の形。Octree と同じ使い方ができる */
export interface CollisionWorld {
  capsuleIntersect(capsule: Capsule): CollisionHit | false
  /** 当たり判定に使っている三角形の数（確認用） */
  readonly triangleCount: number
}

const CELL_SIZE = 1

/** 自分か親が、隠されているか、名前で外す対象か */
function isIgnored(obj: THREE.Object3D, root: THREE.Object3D, filter: CollisionFilter) {
  for (let o: THREE.Object3D | null = obj; o && o !== root; o = o.parent) {
    if (!o.visible) return true
    const name = o.name
    if (filter.prefixes.some((p) => name.startsWith(p))) return true
    if (filter.contains.some((c) => name.includes(c))) return true
  }
  return false
}

const _a = new THREE.Vector3()
const _b = new THREE.Vector3()
const _c = new THREE.Vector3()
const _min = new THREE.Vector3()
const _max = new THREE.Vector3()
const _triangle = new THREE.Triangle()
const _working = new Capsule()
const _center = new THREE.Vector3()
const _start = new THREE.Vector3()

/** 三角形を 1m 角の格子に振り分けた当たり判定 */
class TriangleGrid implements CollisionWorld {
  readonly triangleCount: number
  /** 三角形の頂点（1 つの三角形につき 9 個の数） */
  private readonly positions: Float32Array
  /** 格子ごとの三角形の番号 */
  private readonly cells: number[][]
  private readonly origin: THREE.Vector3
  private readonly dims: [number, number, number]
  /** 1 回の判定で同じ三角形を 2 度調べないための印 */
  private readonly visited: Uint32Array
  private visit = 0
  /** 三角形とカプセルの判定に使う（Octree の triangleCapsuleIntersect） */
  private readonly tester = new Octree()

  constructor(positions: Float32Array) {
    this.positions = positions
    this.triangleCount = positions.length / 9
    this.visited = new Uint32Array(this.triangleCount)

    const bounds = new THREE.Box3()
    for (let i = 0; i < positions.length; i += 3) bounds.expandByPoint(_a.fromArray(positions, i))
    this.origin = bounds.min.clone()
    const size = bounds.getSize(_a)
    this.dims = [
      Math.max(1, Math.ceil(size.x / CELL_SIZE)),
      Math.max(1, Math.ceil(size.y / CELL_SIZE)),
      Math.max(1, Math.ceil(size.z / CELL_SIZE)),
    ]
    this.cells = Array.from({ length: this.dims[0] * this.dims[1] * this.dims[2] }, () => [])

    for (let t = 0; t < this.triangleCount; t++) {
      const o = t * 9
      const min = _a.set(
        Math.min(positions[o], positions[o + 3], positions[o + 6]),
        Math.min(positions[o + 1], positions[o + 4], positions[o + 7]),
        Math.min(positions[o + 2], positions[o + 5], positions[o + 8]),
      )
      const max = _b.set(
        Math.max(positions[o], positions[o + 3], positions[o + 6]),
        Math.max(positions[o + 1], positions[o + 4], positions[o + 7]),
        Math.max(positions[o + 2], positions[o + 5], positions[o + 8]),
      )
      this.forEachCell(min, max, (cell) => cell.push(t))
    }
  }

  capsuleIntersect(capsule: Capsule): CollisionHit | false {
    const r = capsule.radius
    const min = _min.set(
      Math.min(capsule.start.x, capsule.end.x) - r,
      Math.min(capsule.start.y, capsule.end.y) - r,
      Math.min(capsule.start.z, capsule.end.z) - r,
    )
    const max = _max.set(
      Math.max(capsule.start.x, capsule.end.x) + r,
      Math.max(capsule.start.y, capsule.end.y) + r,
      Math.max(capsule.start.z, capsule.end.z) + r,
    )

    // めり込んだ三角形ごとに押し戻し、最後に合計でどれだけ動いたかを返す（Octree と同じ）
    _working.copy(capsule)
    const visit = ++this.visit
    let hit = false
    this.forEachCell(min, max, (cell) => {
      for (const t of cell) {
        if (this.visited[t] === visit) continue
        this.visited[t] = visit
        const o = t * 9
        _triangle.set(_a.fromArray(this.positions, o), _b.fromArray(this.positions, o + 3), _c.fromArray(this.positions, o + 6))
        const result = this.tester.triangleCapsuleIntersect(_working, _triangle)
        if (result) {
          hit = true
          _working.translate(result.normal.multiplyScalar(result.depth))
        }
      }
    })
    if (!hit) return false

    const moved = _working.getCenter(_center).sub(capsule.getCenter(_start))
    const depth = moved.length()
    return { normal: moved.clone().normalize(), depth }
  }

  /** min〜max の範囲にかかる格子を順に渡す */
  private forEachCell(min: THREE.Vector3, max: THREE.Vector3, fn: (cell: number[]) => void) {
    const [nx, ny, nz] = this.dims
    const cellIndex = (v: number, origin: number, n: number) =>
      Math.min(n - 1, Math.max(0, Math.floor((v - origin) / CELL_SIZE)))
    const x0 = cellIndex(min.x, this.origin.x, nx), x1 = cellIndex(max.x, this.origin.x, nx)
    const y0 = cellIndex(min.y, this.origin.y, ny), y1 = cellIndex(max.y, this.origin.y, ny)
    const z0 = cellIndex(min.z, this.origin.z, nz), z1 = cellIndex(max.z, this.origin.z, nz)
    for (let x = x0; x <= x1; x++)
      for (let y = y0; y <= y1; y++)
        for (let z = z0; z <= z1; z++) fn(this.cells[(x * ny + y) * nz + z])
  }
}

/** root（ステージ）の中のメッシュから当たり判定を作る */
export function buildCollisionWorld(root: THREE.Object3D, filter: CollisionFilter): CollisionWorld {
  root.updateWorldMatrix(true, true)

  // 外すもの以外のメッシュの三角形を、ワールド座標で 1 つの配列に集める
  const meshes: THREE.Mesh[] = []
  let count = 0
  root.traverse((obj) => {
    const mesh = obj as THREE.Mesh
    if (!mesh.isMesh || isIgnored(mesh, root, filter)) return
    const geometry = mesh.geometry
    meshes.push(mesh)
    count += (geometry.index ? geometry.index.count : geometry.attributes.position.count) / 3
  })

  const positions = new Float32Array(count * 9)
  let o = 0
  for (const mesh of meshes) {
    const position = mesh.geometry.attributes.position
    const index = mesh.geometry.index
    const n = index ? index.count : position.count
    for (let i = 0; i < n; i++) {
      _a.fromBufferAttribute(position, index ? index.getX(i) : i).applyMatrix4(mesh.matrixWorld)
      positions[o++] = _a.x
      positions[o++] = _a.y
      positions[o++] = _a.z
    }
  }
  return new TriangleGrid(positions)
}
