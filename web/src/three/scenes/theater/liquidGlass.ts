// シアターの Liquid Glass（本物の屈折）。今は下の再生の操作列（と中の再生ボタン）だけに使っている。
//
// 3D の上に浮かぶ操作のうしろの景色を、3D の仕上げの最後（DioramaPost の OutputPass のあと）で
// ボタンの形の中だけ曲げて描く。CSS の backdrop-filter はぼかすだけで曲げられず、SVG のフィルターで曲げる方法は Chrome でしか動かない。
// うしろはどうせ自分で描いている 3D なので、描いた絵そのものを曲げれば、iPhone の Safari も含めてどのブラウザでも本物の屈折になる。
//
// 画面の部品の側（DigestTheater）：ガラスにしたい要素に data-liquid="clear"（すきとおったガラス）か "tint"（色付きのガラス）を付ける。
//   ここが動いているあいだ、要素は背景を透明にして、文字・アイコン・外の影だけを描く（CSS の .theater-root.is-liquid）。
// こちらの側：毎フレーム、その要素の位置・大きさ・角の丸み・見えている濃さ（親の opacity も掛ける）を読み、
//   シェーダーに渡す。押したときの拡大や、操作が薄くなるアニメーションも、そのまま形と濃さに反映される。
import * as THREE from 'three'

/** 一度に描けるガラスの数（これより多い分は描かない） */
export const MAX_GLASS = 16

/**
 * #RRGGBB を、変換しないで sRGB の値のまま入れた色。
 * この仕上げは色の仕上げ（OutputPass で sRGB にしたあと）の絵にかけるので、画面の CSS の色と同じ値で混ぜる。
 * three.js の Color はふつう、読んだ色を内部の線形の色に直してしまうので、入力を「線形」と言って直させない
 */
function srgbRaw(hex: string, target = new THREE.Color()) {
  return target.setStyle(hex, THREE.LinearSRGBColorSpace)
}

export const LiquidGlassShader = {
  name: 'TheaterLiquidGlass',
  uniforms: {
    tDiffuse: { value: null as THREE.Texture | null },
    uResolution: { value: new THREE.Vector2(1, 1) },
    uScale: { value: 1 },
    uCount: { value: 0 },
    /** 中心 xy・半分の幅と高さ（描画の画素。左下が原点） */
    uRect: { value: Array.from({ length: MAX_GLASS }, () => new THREE.Vector4()) },
    /** 角の丸み（画素）・見えている濃さ 0〜1・色付きなら 1 */
    uShape: { value: Array.from({ length: MAX_GLASS }, () => new THREE.Vector4()) },
    /** 色付きのガラスの色（sRGB のまま。readCssColor で CSS 変数から読み直す） */
    uTint: { value: srgbRaw('#426780') },
  },
  vertexShader: /* glsl */ `
    varying vec2 vUv;
    void main() {
      vUv = uv;
      gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
    }
  `,
  fragmentShader: /* glsl */ `
    #define MAX_GLASS ${MAX_GLASS}
    uniform sampler2D tDiffuse;
    uniform vec2 uResolution;
    uniform float uScale;
    uniform int uCount;
    uniform vec4 uRect[MAX_GLASS];
    uniform vec4 uShape[MAX_GLASS];
    uniform vec3 uTint;
    varying vec2 vUv;

    // 角の丸い四角の符号付き距離（外が正、中が負）
    float sdRoundBox(vec2 p, vec2 b, float r) {
      vec2 q = abs(p) - b + r;
      return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    // 景色を画素の位置で読む
    vec3 scene(vec2 px) {
      return texture2D(tDiffuse, clamp(px / uResolution, vec2(0.0), vec2(1.0))).rgb;
    }

    void main() {
      vec2 px = vUv * uResolution;
      vec3 base = scene(px);

      // この画素にかかるガラス（重なっていたら、後ろのもの = 画面で手前のものを使う）
      float d = 1e9;
      vec4 R = vec4(0.0);
      vec4 S = vec4(0.0);
      bool hit = false;
      for (int i = 0; i < MAX_GLASS; i++) {
        if (i >= uCount) break;
        float di = sdRoundBox(px - uRect[i].xy, uRect[i].zw, uShape[i].x);
        if (di < 1.0 && uShape[i].y > 0.001) {
          d = di;
          R = uRect[i];
          S = uShape[i];
          hit = true;
        }
      }
      if (!hit) {
        gl_FragColor = vec4(base, 1.0);
        return;
      }

      vec2 p = px - R.xy;
      vec2 b = R.zw;
      float r = S.x;
      // ふちの外向きの向き（距離の傾き）
      float e = 0.75 * uScale;
      vec2 n = vec2(
        sdRoundBox(p + vec2(e, 0.0), b, r) - sdRoundBox(p - vec2(e, 0.0), b, r),
        sdRoundBox(p + vec2(0.0, e), b, r) - sdRoundBox(p - vec2(0.0, e), b, r)
      );
      n = normalize(n + 1e-6);
      float inside = max(0.0, -d);
      // ガラスの厚みで丸くなっている帯（ふちから中へ）の幅
      float bevel = max(1.0, min(min(b.x, b.y), 16.0 * uScale));
      float edge = 1.0 - clamp(inside / bevel, 0.0, 1.0);
      float bend = edge * edge;

      // 屈折：ふちほど外側の景色を中へ引き込む（凸レンズのふち）。真ん中はほんの少し拡大する
      vec2 off = n * bevel * 0.85 * bend;
      vec2 sp = R.xy + p * 0.94 + off;
      // 色のにじみ（ふちで赤と青が少しずれる）
      vec2 ca = off * 0.16;
      vec3 col = vec3(scene(sp + ca).r, scene(sp).g, scene(sp - ca).b);
      // うっすら曇らせる（すりガラスほどはぼかさない）
      float f = 1.6 * uScale;
      vec3 frost = (scene(sp + vec2(f, f)) + scene(sp + vec2(-f, f)) + scene(sp + vec2(f, -f)) + scene(sp + vec2(-f, -f))) * 0.25;
      col = mix(col, frost, 0.45);

      if (S.z > 0.5) {
        // 色付きのガラス：景色を少し残したまま、色を濃く重ねる
        col = mix(col, uTint, 0.88) + 0.04 * (1.0 - bend);
      } else {
        // すきとおったガラス：少し明るく
        col = mix(col, vec3(1.0), 0.1 + 0.1 * bend);
      }

      // 光：左上から。光に向いたふちは明るく光り、反対側のふちにも中を抜けた光がうっすら出る
      vec2 L = normalize(vec2(-0.55, 0.85));
      float rim = 1.0 - smoothstep(0.0, 2.2 * uScale, inside);
      float facing = max(dot(n, L), 0.0);
      col += rim * (0.28 + 0.6 * facing);
      col += rim * max(dot(n, -L), 0.0) * 0.22;
      // 上半分のやわらかい照り返しと、下のふちの内側の陰（ガラスの厚み）
      col += 0.07 * smoothstep(-b.y * 0.1, b.y, p.y) * (S.z > 0.5 ? 0.6 : 1.0);
      float lower = 1.0 - smoothstep(0.0, 7.0 * uScale, inside);
      col -= lower * max(dot(n, vec2(0.0, -1.0)), 0.0) * 0.1;

      // ふちのなめらかさ（1 画素で混ぜる）と、見えている濃さ
      float cover = clamp(0.5 - d, 0.0, 1.0) * S.y;
      gl_FragColor = vec4(mix(base, clamp(col, 0.0, 1.0), cover), 1.0);
    }
  `,
}

export type GlassUniforms = typeof LiquidGlassShader.uniforms

/** 要素と、その親（root まで）の opacity を掛けた濃さ。見えていなければ 0 */
function visibleOpacity(el: HTMLElement, root: HTMLElement): number {
  let o = 1
  for (let node: HTMLElement | null = el; node && node !== root.parentElement; node = node.parentElement) {
    const cs = getComputedStyle(node)
    if (cs.visibility === 'hidden' || cs.display === 'none') return 0
    o *= Number(cs.opacity)
    if (o < 0.001) return 0
  }
  return o
}

/** 角の丸み（CSS の border-radius）を画素で。% は幅と高さの小さいほうに対して */
function cornerRadius(el: HTMLElement, w: number, h: number): number {
  const raw = getComputedStyle(el).borderTopLeftRadius
  const v = parseFloat(raw)
  if (!Number.isFinite(v)) return 0
  const r = raw.endsWith('%') ? (Math.min(w, h) * v) / 100 : v
  return Math.min(r, Math.min(w, h) / 2)
}

/**
 * 画面の部品から、ガラスの形をシェーダーに入れる。
 * canvas は 3D のキャンバス（ガラスはその上の画素に描く）。描けるガラスが 1 つでもあれば true
 */
export function collectGlass(uniforms: GlassUniforms, root: HTMLElement, canvas: HTMLCanvasElement): boolean {
  const box = canvas.getBoundingClientRect()
  if (box.width < 1 || box.height < 1) return false
  const sx = canvas.width / box.width
  const sy = canvas.height / box.height
  uniforms.uResolution.value.set(canvas.width, canvas.height)
  uniforms.uScale.value = sx

  let count = 0
  for (const el of root.querySelectorAll<HTMLElement>('[data-liquid]')) {
    if (count >= MAX_GLASS) break
    const rect = el.getBoundingClientRect()
    if (rect.width < 2 || rect.height < 2) continue
    if (rect.right < box.left || rect.left > box.right || rect.bottom < box.top || rect.top > box.bottom) continue
    const alpha = visibleOpacity(el, root)
    if (alpha <= 0) continue
    const w = rect.width * sx
    const h = rect.height * sy
    const cx = (rect.left - box.left) * sx + w / 2
    const cy = canvas.height - ((rect.top - box.top) * sy + h / 2)
    uniforms.uRect.value[count].set(cx, cy, w / 2, h / 2)
    uniforms.uShape.value[count].set(cornerRadius(el, rect.width, rect.height) * sx, alpha, el.dataset.liquid === 'tint' ? 1 : 0, 0)
    count++
  }
  uniforms.uCount.value = count
  return count > 0
}

/** 色の CSS 変数（#RRGGBB）をシェーダーの色に。読めなければそのまま */
export function readCssColor(target: THREE.Color, root: HTMLElement, name: string) {
  const raw = getComputedStyle(root).getPropertyValue(name).trim()
  if (/^#[0-9a-f]{6}$/i.test(raw)) srgbRaw(raw, target)
}
