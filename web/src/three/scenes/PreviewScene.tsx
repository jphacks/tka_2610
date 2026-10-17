// ④ 3D プレビュー。館内に置いた台座の上で、作品がゆっくり回る。
import { Suspense } from 'react'
import { OrbitControls } from '@react-three/drei'
import type { Museum } from '../../api'
import { FittedModel, MuseumModel } from './models'
import { Stage } from './Stage'

/** 台座を置く場所（中央ホールの入口寄り）と高さ */
const PREVIEW_SPOT: [number, number, number] = [0, 0, -3.2]
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
  const [x, , z] = PREVIEW_SPOT
  return (
    <Stage camera={{ position: [0.9, 1.7, z - 2.6], fov: 45 }}>
      <Suspense fallback={null}>
        {museum.model_url && (
          <MuseumModel url={museum.model_url} hide={museum.hidden_node_prefixes} onReady={onReady} />
        )}
        {/* 作品の正面（+Z）をカメラ側に向ける */}
        <group position={[x, PEDESTAL_H, z]} rotation-y={Math.PI}>
          <FittedModel url={modelUrl} volume={[1.3, 1.25, 1.1]} />
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
        maxDistance={4.2}
        minPolarAngle={0.2 * Math.PI}
        maxPolarAngle={0.55 * Math.PI}
        autoRotate
        autoRotateSpeed={0.5}
      />
    </Stage>
  )
}
