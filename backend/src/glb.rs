//! 写真(JPEG)から展示用の 3D モデル(GLB)を生成する。
//!
//! - `Frame` : 額縁に入った絵 (絵画・写真・その他)
//! - `Stand` : アクリルスタンド風の立体 (工作)
//!
//! 原点は底面中央、+Y が上、作品の正面は +Z。
//! Web(three.js) でそのまま読み込める。

use serde_json::{json, Value};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Style {
    Frame,
    Stand,
}

impl Style {
    pub fn for_category(category: &str) -> Self {
        if category == "craft" { Style::Stand } else { Style::Frame }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Style::Frame => "frame",
            Style::Stand => "stand",
        }
    }
}

// マテリアル番号
const WOOD: usize = 0;
const MAT_BOARD: usize = 1;
const ART: usize = 2;
const ACRYLIC: usize = 3;
const BASE: usize = 4;

#[derive(Default)]
struct Primitive {
    positions: Vec<[f32; 3]>,
    normals: Vec<[f32; 3]>,
    uvs: Vec<[f32; 2]>,
    indices: Vec<u16>,
}

impl Primitive {
    fn push_quad(&mut self, corners: [[f32; 3]; 4], normal: [f32; 3], uvs: [[f32; 2]; 4]) {
        let base = self.positions.len() as u16;
        for (corner, uv) in corners.into_iter().zip(uvs) {
            self.positions.push(corner);
            self.normals.push(normal);
            self.uvs.push(uv);
        }
        self.indices
            .extend_from_slice(&[base, base + 1, base + 2, base, base + 2, base + 3]);
    }

    /// 各面の頂点は外側から見て反時計回り
    fn push_box(&mut self, min: [f32; 3], max: [f32; 3]) {
        let [x0, y0, z0] = min;
        let [x1, y1, z1] = max;
        let uv = [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]];

        self.push_quad([[x0, y0, z1], [x1, y0, z1], [x1, y1, z1], [x0, y1, z1]], [0.0, 0.0, 1.0], uv);
        self.push_quad([[x1, y0, z0], [x0, y0, z0], [x0, y1, z0], [x1, y1, z0]], [0.0, 0.0, -1.0], uv);
        self.push_quad([[x1, y0, z1], [x1, y0, z0], [x1, y1, z0], [x1, y1, z1]], [1.0, 0.0, 0.0], uv);
        self.push_quad([[x0, y0, z0], [x0, y0, z1], [x0, y1, z1], [x0, y1, z0]], [-1.0, 0.0, 0.0], uv);
        self.push_quad([[x0, y1, z1], [x1, y1, z1], [x1, y1, z0], [x0, y1, z0]], [0.0, 1.0, 0.0], uv);
        self.push_quad([[x0, y0, z0], [x1, y0, z0], [x1, y0, z1], [x0, y0, z1]], [0.0, -1.0, 0.0], uv);
    }

    /// 楕円柱 (台座)。底面は展示台に接するので省略
    fn push_elliptic_cylinder(&mut self, rx: f32, rz: f32, height: f32, segments: u16) {
        let ring = |i: u16| {
            let t = i as f32 / segments as f32 * std::f32::consts::TAU;
            (t.cos(), t.sin())
        };

        // 側面
        let side_start = self.positions.len() as u16;
        for i in 0..=segments {
            let (c, s) = ring(i);
            let n = normalize([c / rx, 0.0, s / rz]);
            let u = i as f32 / segments as f32;
            self.positions.push([rx * c, 0.0, rz * s]);
            self.normals.push(n);
            self.uvs.push([u, 1.0]);
            self.positions.push([rx * c, height, rz * s]);
            self.normals.push(n);
            self.uvs.push([u, 0.0]);
        }
        for i in 0..segments {
            let b0 = side_start + i * 2;
            let t0 = b0 + 1;
            let b1 = b0 + 2;
            let t1 = b0 + 3;
            self.indices.extend_from_slice(&[b0, t1, b1, b0, t0, t1]);
        }

        // 上面
        let center = self.positions.len() as u16;
        self.positions.push([0.0, height, 0.0]);
        self.normals.push([0.0, 1.0, 0.0]);
        self.uvs.push([0.5, 0.5]);
        for i in 0..=segments {
            let (c, s) = ring(i);
            self.positions.push([rx * c, height, rz * s]);
            self.normals.push([0.0, 1.0, 0.0]);
            self.uvs.push([0.5 + c * 0.5, 0.5 + s * 0.5]);
        }
        for i in 0..segments {
            let r0 = center + 1 + i;
            self.indices.extend_from_slice(&[center, r0 + 1, r0]);
        }
    }
}

fn normalize(v: [f32; 3]) -> [f32; 3] {
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-6);
    [v[0] / len, v[1] / len, v[2] / len]
}

/// 画像を貼る四角形。`front` が true なら +Z 向き、false なら -Z 向き
fn image_quad(x0: f32, x1: f32, y0: f32, y1: f32, z: f32, front: bool) -> Primitive {
    let mut p = Primitive::default();
    if front {
        p.push_quad(
            [[x0, y0, z], [x1, y0, z], [x1, y1, z], [x0, y1, z]],
            [0.0, 0.0, 1.0],
            [[0.0, 1.0], [1.0, 1.0], [1.0, 0.0], [0.0, 0.0]],
        );
    } else {
        // 裏から見るとアクリル越しのように左右反転して見える
        p.push_quad(
            [[x1, y0, z], [x0, y0, z], [x0, y1, z], [x1, y1, z]],
            [0.0, 0.0, -1.0],
            [[1.0, 1.0], [0.0, 1.0], [0.0, 0.0], [1.0, 0.0]],
        );
    }
    p
}

/// 長辺を `long_side` にそろえた画像の幅と高さ
fn art_size(width: u32, height: u32, long_side: f32) -> (f32, f32) {
    let aspect = (width.max(1) as f32 / height.max(1) as f32).clamp(0.25, 4.0);
    if aspect >= 1.0 {
        (long_side, long_side / aspect)
    } else {
        (long_side * aspect, long_side)
    }
}

fn frame_parts(width: u32, height: u32) -> Vec<(Primitive, usize)> {
    let (w, h) = art_size(width, height, 1.0);
    let mat = 0.07; // 白いマット(余白)
    let frame = 0.075; // 額縁の幅
    let depth = 0.06;
    let base_h = 0.04;

    let ox = w / 2.0 + mat;
    let oy0 = base_h + frame;
    let oy1 = oy0 + h + mat * 2.0;
    let fz = depth / 2.0;

    let mut wood = Primitive::default();
    wood.push_box([-ox - frame, base_h, -fz], [ox + frame, oy0, fz]);
    wood.push_box([-ox - frame, oy1, -fz], [ox + frame, oy1 + frame, fz]);
    wood.push_box([-ox - frame, oy0, -fz], [-ox, oy1, fz]);
    wood.push_box([ox, oy0, -fz], [ox + frame, oy1, fz]);

    let mut base = Primitive::default();
    base.push_box([-ox - frame - 0.03, 0.0, -0.14], [ox + frame + 0.03, base_h, 0.14]);

    let mut board = Primitive::default();
    board.push_box([-ox, oy0, -fz + 0.004], [ox, oy1, 0.0]);

    let art = image_quad(-w / 2.0, w / 2.0, oy0 + mat, oy1 - mat, 0.002, true);

    vec![(base, WOOD), (wood, WOOD), (board, MAT_BOARD), (art, ART)]
}

fn stand_parts(width: u32, height: u32) -> Vec<(Primitive, usize)> {
    let (w, h) = art_size(width, height, 1.0);
    let margin = 0.035;
    let thickness = 0.024;
    let base_h = 0.05;
    let inset = base_h * 0.5;
    let tz = thickness / 2.0;

    let x0 = -w / 2.0;
    let x1 = w / 2.0;
    let y0 = inset + margin;
    let y1 = y0 + h;

    let mut panel = Primitive::default();
    panel.push_box([x0 - margin, inset, -tz], [x1 + margin, y1 + margin, tz]);

    let front = image_quad(x0, x1, y0, y1, tz + 0.001, true);
    let back = image_quad(x0, x1, y0, y1, -tz - 0.001, false);

    let mut base = Primitive::default();
    base.push_elliptic_cylinder((w * 0.5 + 0.08).max(0.28), 0.22, base_h, 48);

    vec![(base, BASE), (panel, ACRYLIC), (front, ART), (back, ART)]
}

/// JPEG を埋め込んだ GLB を生成する
pub fn build_artwork_glb(texture_jpeg: &[u8], width: u32, height: u32, style: Style) -> Vec<u8> {
    let parts = match style {
        Style::Frame => frame_parts(width, height),
        Style::Stand => stand_parts(width, height),
    };

    let mut bin: Vec<u8> = Vec::new();
    let mut buffer_views: Vec<Value> = Vec::new();
    let mut accessors: Vec<Value> = Vec::new();
    let mut primitives: Vec<Value> = Vec::new();

    let mut push_view = |bin: &mut Vec<u8>, bytes: &[u8], target: Option<u32>| -> usize {
        while bin.len() % 4 != 0 {
            bin.push(0);
        }
        let offset = bin.len();
        bin.extend_from_slice(bytes);
        let mut view = json!({
            "buffer": 0,
            "byteOffset": offset,
            "byteLength": bytes.len(),
        });
        if let Some(target) = target {
            view["target"] = json!(target);
        }
        buffer_views.push(view);
        buffer_views.len() - 1
    };

    for (prim, material) in &parts {
        let count = prim.positions.len();

        let mut min = [f32::MAX; 3];
        let mut max = [f32::MIN; 3];
        for p in &prim.positions {
            for k in 0..3 {
                min[k] = min[k].min(p[k]);
                max[k] = max[k].max(p[k]);
            }
        }

        let positions: Vec<u8> = prim.positions.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
        let normals: Vec<u8> = prim.normals.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
        let uvs: Vec<u8> = prim.uvs.iter().flatten().flat_map(|v| v.to_le_bytes()).collect();
        let indices: Vec<u8> = prim.indices.iter().flat_map(|v| v.to_le_bytes()).collect();

        let pos_view = push_view(&mut bin, &positions, Some(34962));
        accessors.push(json!({
            "bufferView": pos_view, "componentType": 5126, "count": count,
            "type": "VEC3", "min": min, "max": max,
        }));
        let pos_acc = accessors.len() - 1;

        let nrm_view = push_view(&mut bin, &normals, Some(34962));
        accessors.push(json!({ "bufferView": nrm_view, "componentType": 5126, "count": count, "type": "VEC3" }));
        let nrm_acc = accessors.len() - 1;

        let uv_view = push_view(&mut bin, &uvs, Some(34962));
        accessors.push(json!({ "bufferView": uv_view, "componentType": 5126, "count": count, "type": "VEC2" }));
        let uv_acc = accessors.len() - 1;

        let idx_view = push_view(&mut bin, &indices, Some(34963));
        accessors.push(json!({
            "bufferView": idx_view, "componentType": 5123,
            "count": prim.indices.len(), "type": "SCALAR",
        }));
        let idx_acc = accessors.len() - 1;

        primitives.push(json!({
            "attributes": { "POSITION": pos_acc, "NORMAL": nrm_acc, "TEXCOORD_0": uv_acc },
            "indices": idx_acc,
            "material": material,
        }));
    }

    let image_view = push_view(&mut bin, texture_jpeg, None);
    while bin.len() % 4 != 0 {
        bin.push(0);
    }

    let solid = |name: &str, color: [f32; 4], roughness: f32| {
        json!({
            "name": name,
            "pbrMetallicRoughness": {
                "baseColorFactor": color,
                "metallicFactor": 0.0,
                "roughnessFactor": roughness,
            },
        })
    };

    let materials = json!([
        // 詳細画面の額縁と同じ濃いウォルナット
        solid("Wood", [0.16, 0.11, 0.08, 1.0], 0.5),
        solid("MatBoard", [0.97, 0.95, 0.90, 1.0], 0.9),
        {
            "name": "Artwork",
            "pbrMetallicRoughness": {
                "baseColorTexture": { "index": 0 },
                "metallicFactor": 0.0,
                "roughnessFactor": 0.85,
            },
        },
        solid("Acrylic", [0.96, 0.97, 0.98, 1.0], 0.15),
        solid("StandBase", [0.93, 0.86, 0.78, 1.0], 0.35),
    ]);

    let document = json!({
        "asset": { "version": "2.0", "generator": "memory-museum-backend" },
        "scene": 0,
        "scenes": [{ "nodes": [0] }],
        "nodes": [{ "name": format!("Artwork_{}", style.as_str()), "mesh": 0 }],
        "meshes": [{ "name": "Artwork", "primitives": primitives }],
        "materials": materials,
        "textures": [{ "source": 0, "sampler": 0 }],
        "samplers": [{ "magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071 }],
        "images": [{ "bufferView": image_view, "mimeType": "image/jpeg" }],
        "accessors": accessors,
        "bufferViews": buffer_views,
        "buffers": [{ "byteLength": bin.len() }],
    });

    let mut json_bytes = serde_json::to_vec(&document).expect("glTF JSON serialization");
    while json_bytes.len() % 4 != 0 {
        json_bytes.push(b' ');
    }

    let total = 12 + 8 + json_bytes.len() + 8 + bin.len();
    let mut out = Vec::with_capacity(total);
    out.extend_from_slice(b"glTF");
    out.extend_from_slice(&2u32.to_le_bytes());
    out.extend_from_slice(&(total as u32).to_le_bytes());
    out.extend_from_slice(&(json_bytes.len() as u32).to_le_bytes());
    out.extend_from_slice(b"JSON");
    out.extend_from_slice(&json_bytes);
    out.extend_from_slice(&(bin.len() as u32).to_le_bytes());
    out.extend_from_slice(b"BIN\0");
    out.extend_from_slice(&bin);
    out
}

/// アップロードされた GLB の最低限の検証 (glTF 2.0 バイナリか)
pub fn validate_glb(data: &[u8]) -> Result<(), String> {
    if data.len() < 12 {
        return Err("GLB ファイルが小さすぎます".into());
    }
    if &data[0..4] != b"glTF" {
        return Err("GLB 形式ではありません".into());
    }
    let version = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    if version != 2 {
        return Err(format!("未対応の GLB バージョンです: {version}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(glb: &[u8]) -> Value {
        assert_eq!(&glb[0..4], b"glTF");
        let total = u32::from_le_bytes(glb[8..12].try_into().unwrap()) as usize;
        assert_eq!(total, glb.len());
        let json_len = u32::from_le_bytes(glb[12..16].try_into().unwrap()) as usize;
        assert_eq!(&glb[16..20], b"JSON");
        serde_json::from_slice(&glb[20..20 + json_len]).unwrap()
    }

    #[test]
    fn builds_valid_glb_for_both_styles() {
        let fake_jpeg = vec![0xFFu8, 0xD8, 0xFF, 0xD9, 1, 2, 3];
        for style in [Style::Frame, Style::Stand] {
            let glb = build_artwork_glb(&fake_jpeg, 800, 600, style);
            validate_glb(&glb).unwrap();
            let doc = parse(&glb);
            let prims = doc["meshes"][0]["primitives"].as_array().unwrap();
            assert!(prims.len() >= 4);
            for view in doc["bufferViews"].as_array().unwrap() {
                assert_eq!(view["byteOffset"].as_u64().unwrap() % 4, 0);
            }
            let bin_len = doc["buffers"][0]["byteLength"].as_u64().unwrap() as usize;
            assert_eq!(bin_len % 4, 0);
        }
    }

    #[test]
    fn art_size_keeps_aspect() {
        assert_eq!(art_size(400, 200, 1.0), (1.0, 0.5));
        assert_eq!(art_size(200, 400, 1.0), (0.5, 1.0));
    }
}
