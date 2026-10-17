// ④ 3D プレビュー。リビング（中央の部屋）の真ん中に置いた台座の上で、作品をゆっくり回して見る。
// 家具やほかの作品は置かず、手前（カメラの側の 2 面）の壁はカットする（カメラが回ると、カットする壁も入れ替わる。HouseShells）。
// カメラは南東から始めて、部屋の中をゆっくり回る。
// 建物は全部の部屋を置く（リビングの壁の開口から、隣の部屋が見えるように）。
import { Suspense } from 'react'
import { OrbitControls } from '@react-three/drei'
import type { Museum } from '../../api'
import { HouseShells } from './home/HouseShells'
import { roomOrigin } from './home/placement'
import { FittedModel } from './models'
import { Stage } from './Stage'

/** 台座の高さ */
const PEDESTAL_H = 0.92

export function PreviewScene({
  museum,
  modelUrl,
  onReady,
}: {
  museum: Museum
  modelUrl: string
  onReady?: () => void
}) {
  // 台座を置く場所：リビングの中心（house.rooms の origin）
  const [x, z] = roomOrigin(museum.house, 'hub')
  return (
    <Stage camera={{ position: [x + 1.7, 1.75, z + 1.9], fov: 45 }}>
      <HouseShells museum={museum} cutaway onReady={onReady} />
      <Suspense fallback={null}>
        {/* 作品の正面（+Z）を、はじめのカメラ（南東）の側に向ける */}
        <group position={[x, PEDESTAL_H, z]} rotation-y={Math.PI / 4}>
          <FittedModel url={modelUrl} fit={[1.3, 1.25, 1.1]} />
        </group>
      </Suspense>
      <mesh position={[x, PEDESTAL_H / 2, z]}>
        <cylinderGeometry args={[0.5, 0.56, PEDESTAL_H, 48]} />
        <meshStandardMaterial color="#f4ece1" roughness={0.55} />
      </mesh>
      <OrbitControls
        makeDefault
        target={[x, PEDESTAL_H + 0.5, z]}
        enableDamping
        enablePan={false}
        minDistance={1.3}
        // 部屋（半分の幅 4 m）の中から出ないようにする
        maxDistance={3.2}
        minPolarAngle={0.2 * Math.PI}
        maxPolarAngle={0.55 * Math.PI}
        autoRotate
        autoRotateSpeed={0.5}
      />
    </Stage>
  )
}
