// three.js のキャンバスと照明。ホーム・おうちの中・マップ・3D プレビューの 4 つの 3D 画面の土台になる
// （鑑賞モードの照明は walk/lighting.tsx）。3D 全体の明るさや背景色を変えるときはここを触る。
// 照明は 10 × 10 m のリビングに合わせた大きさで、影は付けない（斜め上から見る画面なので、やわらかく均一に照らす）。

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
  /** 'demand' にすると、動きがあるときだけ描画する（マップで使う） */
  frameloop?: 'always' | 'demand'
}) {
  return (
    <Canvas
      dpr={[1, 1.75]}
      frameloop={frameloop}
      camera={{ ...camera, near: 0.1, far: 80 }}
      gl={{ antialias: true, powerPreference: 'high-performance' }}
      onCreated={({ gl }) => {
        // 子どもの絵の色がくすまないトーンマッピング
        gl.toneMapping = THREE.NeutralToneMapping
        gl.toneMappingExposure = 1.05
      }}
    >
      <color attach="background" args={['#efe2d0']} />
      <HomeLights />
      {children}
    </Canvas>
  )
}

function HomeLights() {
  return (
    <>
      <hemisphereLight args={['#fff8ee', '#cbb497', 1.05]} />
      {/* 主な光は、はじめのカメラのある南東の斜め上から。そこから見た奥の壁（北・西）の内側がよく照らされる */}
      <directionalLight position={[4, 8, 5]} intensity={1.4} color="#fff0db" />
      {/* 反対側からの弱い光。家具の陰になる面を少し明るくする */}
      <directionalLight position={[-5, 6, -3]} intensity={0.45} color="#ffe6cc" />
      {/* 外部 HDR を読まずに、その場で柔らかい環境光を作る（家の大きさに合わせた天井と左右の明かり） */}
      <Environment resolution={64} frames={1}>
        <Lightformer form="rect" intensity={2.2} position={[0, 4.5, 0]} rotation-x={Math.PI / 2} scale={[15, 15, 1]} color="#fff6e8" />
        <Lightformer form="rect" intensity={0.9} position={[0, 1, -7.5]} scale={[15, 2.5, 1]} color="#ffe5c7" />
        <Lightformer form="rect" intensity={0.9} position={[0, 1, 7.5]} rotation-y={Math.PI} scale={[15, 2.5, 1]} color="#ffe5c7" />
      </Environment>
    </>
  )
}
