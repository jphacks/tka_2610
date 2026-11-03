/** 表示用の回転だけを扱う。作品の選択・並び順はRustから受け取る。 */
export function smoothTurn(progress: number) {
  const t = Math.max(0, Math.min(1, progress))
  return t * t * t * (t * (t * 6 - 15) + 10)
}

/** 現在と前後の作品だけGLBを置く。1〜2作品でも重複させない。 */
export function nearbyIndices(index: number, count: number) {
  if (!count) return []
  return [...new Set([index, (index - 1 + count) % count, (index + 1) % count])]
}
