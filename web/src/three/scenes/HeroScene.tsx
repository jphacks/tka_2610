// ② ホームのヒーロー。入口から館内をゆっくり見回す。
import { Suspense } from 'react'
import { useFrame } from '@react-three/fiber'
import type { Museum } from '../../api'
import { MuseumModel, SlotArtworks } from './models'
import { Stage } from './Stage'

/** カメラを左右・前後にゆっくり揺らす */
function Drift() {
  useFrame(({ camera, clock }) => {
    const t = clock.getElapsedTime()
    const x = Math.sin(t * 0.11) * 2.4
    camera.position.set(x, 2.3 + Math.sin(t * 0.19) * 0.15, -11.6 + Math.sin(t * 0.07) * 1.1)
    camera.lookAt(x * 0.35, 2.5, 3)
  })
  return null
}

export function HeroScene({ museum, onReady }: { museum: Museum; onReady?: () => void }) {
  if (!museum.model_url) return null
  return (
    <Stage camera={{ position: [0, 2.3, -11.6], fov: 58 }}>
      <Suspense fallback={null}>
        <MuseumModel url={museum.model_url} hide={museum.hidden_node_prefixes} onReady={onReady} />
        <SlotArtworks slots={museum.slots} />
      </Suspense>
      <Drift />
    </Stage>
  )
}
