// 一人称で歩く画面で、最後に立っていた位置と向き。
// 作品カードから作品の詳細画面へ移って戻ったときに、同じ場所から歩き続けられるように覚えておく。
// three.js を使わないので、画面（pages/MuseumWalk.tsx）からも読める（three/index.tsx から渡している）。

export interface WalkPose {
  /** 足もとの位置 */
  feet: [number, number, number]
  /** 水平・上下の向き（ラジアン） */
  yaw: number
  pitch: number
}

let saved: WalkPose | null = null

export const getWalkPose = () => saved
export const saveWalkPose = (pose: WalkPose) => {
  saved = pose
}
/** 次に歩く画面を開いたときは、はじめの位置から歩き始める */
export const clearWalkPose = () => {
  saved = null
}
