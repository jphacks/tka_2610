// 鑑賞モード（家の中を一人称で歩く画面）のステージの設定（はじめの位置・歩き方・カメラ・照明・当たり判定から外すもの）。
//
// 家の建物の GLB は /api/museum の house.rooms[].model_url（部屋ごと。Rust: home.rs の ROOM_DEFS）から読む
// （house の無い古いサーバーでは model_url の 1 つ）。
// 家は中央の 8 × 8 m のリビング（中心が原点）と、その西・東・北に壁を共有して並ぶ 6 × 6 m の 3 部屋。床が y = 0、天井の高さは 3.2 m。
// 部屋の位置と大きさはここに書かず、house.rooms から天井の板とダウンライト（roomDownlights）を部屋ごとに作る。
// 歩き方の数値は Unity 版の博物館（unity/Assets/MemoryMuseum/Scripts/MuseumWalker.cs）と同じ。
// 照明の数値は家に合わせて決めたこの画面の値。書き方（Unity の単位）と three.js への換算は lighting.tsx。
// 将来、部屋を増やしたり照明を動かしたりするときは、この形のデータをサーバーから受け取る想定。

export type Vec3 = [number, number, number]

/** 歩く人の大きさと動き（Unity の CharacterController と MuseumWalker と同じ） */
export interface PlayerSpec {
  /** 体の高さ・太さ（m） */
  height: number
  radius: number
  /** 足もとから目までの高さ（m） */
  eyeHeight: number
  /** 歩く速さ・Shift を押したときの速さ（m/秒） */
  walkSpeed: number
  runSpeed: number
  /** 重力（m/秒²）と、落ちる速さの上限（m/秒） */
  gravity: number
  maxFallSpeed: number
  /** これより急な面は床ではなく壁として扱う（度） */
  slopeLimitDeg: number
  /** これより低い段差は、引っかからずに上がれる（m） */
  stepHeight: number
  /** これより下に落ちたら、はじめの位置に戻す（y, m） */
  rescueBelowY: number
  /** マウスを 1px 動かしたときに視点が回る角度（度） */
  lookDegPerPixel: number
  /** 上下を向ける範囲（度） */
  pitchLimitDeg: number
}

/** Unity のスポットライト 1 つ。強さは Unity の値のまま（three.js への換算は lighting.tsx） */
export interface SpotLightSpec {
  position: Vec3
  /** Unity の色（sRGB） */
  color: Vec3
  /** Unity の intensity */
  power: number
  /** 光が届く距離（m） */
  range: number
  /** 光の広がり（円錐の頂角, 度） */
  angleDeg: number
}

export interface StagePreset {
  /** はじめに立つ位置（足もと） */
  spawn: Vec3
  /** はじめに向く先（水平の向きだけ使う） */
  lookAt: Vec3
  player: PlayerSpec
  camera: { fov: number; near: number; far: number }
  /** 太陽（天井は影を落とさないので、天窓から差すように床を照らす）。向きは Unity の Euler 角（x: 見下ろす角度, y: 水平の向き）、色は sRGB */
  sun: { eulerDeg: [number, number]; color: Vec3; power: number; shadowStrength: number }
  /** 環境光（Unity の Trilight。上・横・下から来る光の色, sRGB） */
  ambient: { sky: Vec3; equator: Vec3; ground: Vec3 }
  /** 映り込み用に部屋の中を撮る位置と、映り込みの強さ（Unity の反射プローブ）。リビングの中から撮る */
  reflection: { position: Vec3; intensity: number }
  /** 天井の照明（真下に向けたスポットライト。影なし）。部屋の定義が無いとき（リビングだけ）の値 */
  spotLights: SpotLightSpec[]
  /** 部屋ごとの天井の照明の並べ方（house.rooms から roomDownlights で作る） */
  roomLights: RoomLightSpec
  /** 光る材質（照明器具の電球）。GLB に発光の強さが残っていないときに、ここで補う */
  emissive: { material: string; strength: number }[]
  /** 当たり判定に使わないノード（名前の先頭・名前に含まれる文字）。作品・天井や、上を歩ける敷物 */
  collisionIgnore: { prefixes: string[]; contains: string[] }
  /**
   * 材質の色（baseColorFactor）を sRGB として読み直すか（stageMaterials.ts の 1）。
   * 博物館の GLB は Unity の sRGB の色がそのまま入っていたので true にしていた。家の GLB は glTF の決まりどおり（リニア）なので false
   */
  legacyUnityColors: boolean
}

/** 天井の高さ（m）。家の GLB の壁の高さと同じ。WalkScene はこの高さに部屋ごとの天井の板を張る */
export const CEILING_HEIGHT = 3.2

/**
 * 部屋ごとのダウンライトの並べ方（roomDownlights が house.rooms から灯の位置を作る）。
 * 大きい部屋（リビング 8 × 8）は四隅寄りと中央の 5 灯、小さい部屋（6 × 6）は中央と ±1.8 m の 3 灯。
 * スマホなどの軽い表示（lite）では、小さい部屋は中央の 1 灯だけにする（smallLite）
 */
export interface RoomLightSpec {
  /** 灯の色・強さ・届く距離・広がり（位置のほかは全部の部屋で同じ） */
  light: Omit<SpotLightSpec, 'position'>
  /** 灯の高さ（m） */
  y: number
  /** 短い辺がこれ以上（m）の部屋は large、それより小さい部屋は small の並べ方 */
  largeMinSize: number
  /** 大きい部屋の灯の位置（部屋の中心から見た x, z） */
  large: [number, number][]
  /**
   * 小さい部屋の灯の位置（部屋の中心から、[長い向き, 直角の向き]）。
   * 長い向きは、家の中心（リビング）からその部屋へ向かう向き（左右の部屋は x、前の部屋は z）。入口から奥へ 1 列に並ぶ
   */
  small: [number, number][]
  /**
   * 軽い表示（lite。タッチの端末）での小さい部屋の灯の位置（small と同じ書き方）。
   * three.js はライトの数だけ画面の全部の点で計算するので、スマホでは数を減らす。部屋の明るさは環境光と太陽で保たれる
   */
  smallLite: [number, number][]
}

// 天井のダウンライト 5 灯（部屋の四隅寄りと中央）。真下に向けた広いスポットライト
// 強さ（power）2.2・距離（range）7 だと、ダウンライトの真下の床が白く飛んでいた。
// power は Unity の書き方で「sRGB の色 × power」をリニアに直すので、2.2 → 1.0 でリニアの明るさは約 6.2 → 1.0 になる。
// lighting.tsx の換算で床（天井から 3.15 m）の直接光を見積もると、白い面がそのままの色に見える明るさを 1 として、
// 真ん中の灯の真下（届く灯の合計）で約 2.6 → 約 0.3。部屋全体の明るさは環境光（白い面で約 0.9）と太陽で保ち、ダウンライトは床に淡い光だまりを作る程度にする。
// range を 7 → 6 にすると、隣の灯の光が重なる所（灯から 4 m ほど）でより早く弱まる。
// 6 × 6 の部屋は中央と、奥行きの向きに ±1.8 m の 3 灯（壁から 1.2 m。リビングの灯の壁からの距離 2 m より壁に近いが、部屋が狭い分）。
// 軽い表示（スマホ）では、6 × 6 の部屋は中央の 1 灯だけ（4 部屋で 14 灯 → 8 灯）。
const ROOM_LIGHTS: RoomLightSpec = {
  light: { color: [1, 0.93, 0.82], power: 1.0, range: 6, angleDeg: 100 },
  y: 3.15,
  largeMinSize: 7,
  large: [
    [-2, -2],
    [2, -2],
    [0, 0],
    [-2, 2],
    [2, 2],
  ],
  small: [
    [-1.8, 0],
    [0, 0],
    [1.8, 0],
  ],
  smallLite: [[0, 0]],
}

/** 部屋 1 つ（house.rooms[] の位置と大きさ） */
export interface LitRoom {
  origin: [number, number]
  size: [number, number]
}

/**
 * 部屋ごとのダウンライト（世界座標）。spec の並べ方を、部屋の中心と大きさに合わせて置く。
 * lite（スマホなどの軽い表示）では、小さい部屋に smallLite の並べ方を使う
 */
export function roomDownlights(spec: RoomLightSpec, rooms: LitRoom[], lite = false): SpotLightSpec[] {
  const lights: SpotLightSpec[] = []
  const small = lite ? spec.smallLite : spec.small
  for (const { origin, size } of rooms) {
    const [ox, oz] = origin
    const large = Math.min(size[0], size[1]) >= spec.largeMinSize
    // 小さい部屋の長い向き：家の中心からその部屋へ向かう向き（中心にある部屋は x）
    const alongX = Math.abs(ox) >= Math.abs(oz)
    const offsets = large ? spec.large : small.map(([a, b]): [number, number] => (alongX ? [a, b] : [b, a]))
    for (const [x, z] of offsets) lights.push({ ...spec.light, position: [ox + x, spec.y, oz + z] })
  }
  return lights
}

/** リビング（8 × 8 m、中心が原点）だけの家のダウンライト（house の無い古いサーバーのとき） */
const DOWNLIGHTS: SpotLightSpec[] = roomDownlights(ROOM_LIGHTS, [{ origin: [0, 0], size: [8, 8] }])

/** 家の設定 */
export const HOME_STAGE: StagePreset = {
  // 南側（工作机の手前）から、部屋の中央（ソファの方）を向いて立つ
  spawn: [0, 0.12, 2.2],
  lookAt: [0, 0, 0],
  player: {
    height: 1.8,
    radius: 0.26,
    eyeHeight: 1.62,
    walkSpeed: 2.8,
    runSpeed: 4.6,
    gravity: 18,
    maxFallSpeed: 25,
    slopeLimitDeg: 50,
    stepHeight: 0.3,
    rescueBelowY: -3,
    lookDegPerPixel: 0.2,
    pitchLimitDeg: 82,
  },
  camera: { fov: 61, near: 0.045, far: 60 },
  // 太陽も 1.2 → 0.9（リニアで約 0.52 倍）。床の白飛びを抑えるため。環境光（ambient）は変えず、陰の明るさは保つ
  sun: { eulerDeg: [50, -35], color: [1, 0.94, 0.84], power: 0.9, shadowStrength: 0.6 },
  ambient: { sky: [1, 0.97, 0.91], equator: [0.86, 0.82, 0.74], ground: [0.69, 0.65, 0.55] },
  reflection: { position: [0, 1.6, 0], intensity: 0.4 },
  spotLights: DOWNLIGHTS,
  roomLights: ROOM_LIGHTS,
  emissive: [],
  collisionIgnore: {
    // 作品（HomeObjects の ARTWORK_）と天井には当たらない。ラグは上を歩く
    prefixes: ['ARTWORK_', 'Ceiling'],
    contains: ['home_rug'],
  },
  legacyUnityColors: false,
}
