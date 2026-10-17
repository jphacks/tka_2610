// three.js のキャンバスと照明。4 つの 3D 画面すべての土台になる。
// 3D 全体の明るさや背景色を変えるときはここを触る。

import type { ReactNode } from 'react'
import { Canvas } from '@react-three/fiber'
import { Environment, Lightformer } from '@react-three/drei'
import * as THREE from 'three'

export function Stage({
  children,
  camera,
  frameloop = 'always',
}: {
  children: ReactNode
  camera: { position: [number, number, number]; fov: number }
  /** 'demand' にすると、動きがあるときだけ描画する（見取り図で使う） */
  frameloop?: 'always' | 'demand'
}) {
  return (
    <Canvas
      dpr={[1, 1.75]}
      frameloop={frameloop}
      camera={{ ...camera, near: 0.1, far: 120 }}
      gl={{ antialias: true, powerPreference: 'high-performance' }}
      onCreated={({ gl }) => {
        // 子どもの絵の色がくすまないトーンマッピング
        gl.toneMapping = THREE.NeutralToneMapping
        gl.toneMappingExposure = 1.05
      }}
    >
      <color attach="background" args={['#efe2d0']} />
      <MuseumLights />
      {children}
    </Canvas>
  )
}

function MuseumLights() {
  return (
    <>
      <hemisphereLight args={['#fff8ee', '#cbb497', 1.1]} />
      <directionalLight position={[8, 14, -6]} intensity={1.6} color="#fff0db" />
      <directionalLight position={[-6, 10, 8]} intensity={0.5} color="#ffe6cc" />
      {/* 外部 HDR を読まずに、その場で柔らかい環境光を作る */}
      <Environment resolution={64} frames={1}>
        <Lightformer form="rect" intensity={2.2} position={[0, 9, 0]} rotation-x={Math.PI / 2} scale={[24, 24, 1]} color="#fff6e8" />
        <Lightformer form="rect" intensity={0.9} position={[0, 2, -12]} scale={[24, 5, 1]} color="#ffe5c7" />
        <Lightformer form="rect" intensity={0.9} position={[0, 2, 12]} rotation-y={Math.PI} scale={[24, 5, 1]} color="#ffe5c7" />
      </Environment>
    </>
  )
}
