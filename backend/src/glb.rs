//! 写真(JPEG)から展示用の 3D モデル(GLB)を生成する。
//!
//! - `Frame` : オークの額縁に入れた写真 (絵画・写真・その他)。額縁は backend/static/frames の GLB (縦長・横長・正方形)
//! - `Stand` : アクリルスタンド風の立体 (工作)
//!
//! 原点は底面中央、+Y が上、作品の正面は +Z。
//! Web(three.js) でそのまま読み込める。

use image::GenericImageView;
use serde_json::{json, Value};

use crate::media;

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

// マテリアル番号 (スタンド)
const ART: usize = 0;
const ACRYLIC: usize = 1;
const BASE: usize = 2;

/// 写真を入れるオークの額縁 (写真面の幅 / 高さ、GLB)。壁掛けの額縁で、原点は額縁の中心、背面が z = 0、正面が +Z。
/// 写真の差し込み先は Photo_Surface (UV の原点は左上)。テクスチャは 512px に縮めてある (作品ごとの GLB に入るため)
const OAK_FRAMES: [(f64, &[u8]); 3] = [
    (2.0 / 3.0, include_bytes!("../static/frames/oak_frame_portrait.glb")),
    (1.0, include_bytes!("../static/frames/oak_frame_square.glb")),
    (1.5, include_bytes!("../static/frames/oak_frame_landscape.glb")),
];
/// 額縁で作った GLB の asset.generator。起動時に、これでない額縁の作品を作り直す (artworks::upgrade_frames)
pub const OAK_FRAME_GENERATOR: &str = "memoria oak frame v1";
/// 額縁を後ろへ傾ける角度 (度)。棚や机・ピクチャーレッジに立てかけたように見せる
const OAK_FRAME_TILT_DEG: f64 = 8.0;

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
    match style {
        Style::Frame => build_oak_frame_glb(texture_jpeg, width, height),
        Style::Stand => build_stand_glb(texture_jpeg, width, height),
    }
}

/// 写真の縦横に近い額縁 (写真面の幅 / 高さと GLB)
fn oak_frame_for(width: u32, height: u32) -> (f64, &'static [u8]) {
    let aspect = (width.max(1) as f64 / height.max(1) as f64).ln();
    OAK_FRAMES
        .into_iter()
        .min_by(|a, b| (a.0.ln() - aspect).abs().total_cmp(&(b.0.ln() - aspect).abs()))
        .expect("oak frames")
}

/// 写真を額縁の写真面の縦横に合わせて、真ん中を切り抜く (引き伸ばさない)。読めなければそのまま
fn crop_to_aspect(jpeg: &[u8], aspect: f64) -> Vec<u8> {
    let Ok(image) = image::load_from_memory(jpeg) else { return jpeg.to_vec() };
    let (w, h) = image.dimensions();
    let (cw, ch) = if (w as f64 / h as f64) > aspect {
        (((h as f64 * aspect).round() as u32).clamp(1, w), h)
    } else {
        (w, ((w as f64 / aspect).round() as u32).clamp(1, h))
    };
    if (cw, ch) == (w, h) {
        return jpeg.to_vec();
    }
    media::encode_jpeg(&image.crop_imm((w - cw) / 2, (h - ch) / 2, cw, ch), 85)
}

/// GLB の JSON のチャンクだけを読む (読めなければ None)
pub fn split_json(glb: &[u8]) -> Option<Value> {
    split_glb(glb).ok().map(|(doc, _)| doc)
}

/// GLB を JSON と BIN に分ける
fn split_glb(glb: &[u8]) -> Result<(Value, Vec<u8>), String> {
    let chunk = |at: usize| -> Result<(usize, &[u8; 4]), String> {
        let len = glb.get(at..at + 4).ok_or("GLB が短すぎます")?;
        let kind = glb.get(at + 4..at + 8).ok_or("GLB が短すぎます")?;
        Ok((u32::from_le_bytes(len.try_into().unwrap()) as usize, kind.try_into().unwrap()))
    };
    let (json_len, kind) = chunk(12)?;
    if kind != b"JSON" {
        return Err("GLB の JSON のチャンクがありません".into());
    }
    let json_end = 20 + json_len;
    let doc: Value = serde_json::from_slice(glb.get(20..json_end).ok_or("GLB が短すぎます")?).map_err(|e| e.to_string())?;
    let (bin_len, kind) = chunk(json_end)?;
    if kind != b"BIN\0" {
        return Err("GLB の BIN のチャンクがありません".into());
    }
    let bin = glb.get(json_end + 8..json_end + 8 + bin_len).ok_or("GLB が短すぎます")?.to_vec();
    Ok((doc, bin))
}

/// オークの額縁に写真を入れた GLB。写真に近い縦横の額縁を選び、写真をその縦横に切り抜いて Photo_Surface に貼る。
/// 額縁を少し後ろへ傾け、全体の箱の底面の中央が原点に来るよう、親のノード (Artwork_frame) で動かす
fn build_oak_frame_glb(texture_jpeg: &[u8], width: u32, height: u32) -> Vec<u8> {
    let (aspect, template) = oak_frame_for(width, height);
    let photo = crop_to_aspect(texture_jpeg, aspect);
    let (mut doc, mut bin) = split_glb(template).expect("backend/static/frames の額縁の GLB");

    // 写真を BIN の後ろに足して、Photo_Surface の材質に貼る
    while bin.len() % 4 != 0 {
        bin.push(0);
    }
    let offset = bin.len();
    bin.extend_from_slice(&photo);
    while bin.len() % 4 != 0 {
        bin.push(0);
    }
    let push = |doc: &mut Value, key: &str, item: Value| -> usize {
        let list = doc[key].as_array_mut().expect("glTF の配列");
        list.push(item);
        list.len() - 1
    };
    let view = push(&mut doc, "bufferViews", json!({ "buffer": 0, "byteOffset": offset, "byteLength": photo.len() }));
    let image = push(&mut doc, "images", json!({ "name": "Photo", "bufferView": view, "mimeType": "image/jpeg" }));
    let sampler = push(&mut doc, "samplers", json!({ "magFilter": 9729, "minFilter": 9987, "wrapS": 33071, "wrapT": 33071 }));
    let texture = push(&mut doc, "textures", json!({ "source": image, "sampler": sampler }));
    doc["buffers"][0]["byteLength"] = json!(bin.len());

    let node_named = |doc: &Value, name: &str| {
        doc["nodes"].as_array().and_then(|nodes| nodes.iter().position(|n| n["name"] == name)).expect("額縁のノード")
    };
    let photo_mesh = doc["nodes"][node_named(&doc, "Photo_Surface")]["mesh"].as_u64().expect("写真面のメッシュ") as usize;
    let photo_material = doc["meshes"][photo_mesh]["primitives"][0]["material"].as_u64().expect("写真面の材質") as usize;
    doc["materials"][photo_material]["pbrMetallicRoughness"]["baseColorTexture"] = json!({ "index": texture });

    // 額縁本体の箱 (幅・高さは中心から、奥行きは背面 0 から正面まで) を傾けて、底面の中央を原点へ
    let body_mesh = doc["nodes"][node_named(&doc, "Frame_Body")]["mesh"].as_u64().expect("額縁本体のメッシュ") as usize;
    let accessor = doc["meshes"][body_mesh]["primitives"][0]["attributes"]["POSITION"].as_u64().expect("額縁本体の頂点") as usize;
    let bound = |key: &str, k: usize| doc["accessors"][accessor][key][k].as_f64().expect("額縁本体の min / max");
    let (min, max) = ([bound("min", 0), bound("min", 1), bound("min", 2)], [bound("max", 0), bound("max", 1), bound("max", 2)]);
    // x 軸まわりに -tilt 回す (上が奥 -Z へ倒れる)
    let tilt = -OAK_FRAME_TILT_DEG.to_radians();
    let (sin, cos) = tilt.sin_cos();
    let (mut lo, mut hi) = ([f64::MAX; 3], [f64::MIN; 3]);
    for &y in &[min[1], max[1]] {
        for &z in &[min[2], max[2]] {
            let p = [0.0, y * cos - z * sin, y * sin + z * cos];
            for k in 1..3 {
                lo[k] = lo[k].min(p[k]);
                hi[k] = hi[k].max(p[k]);
            }
        }
    }
    let translation = [-(min[0] + max[0]) / 2.0, -lo[1], -(lo[2] + hi[2]) / 2.0];
    let scene = doc["scene"].as_u64().unwrap_or(0) as usize;
    let children = doc["scenes"][scene]["nodes"].clone();
    let root = push(&mut doc, "nodes", json!({
        "name": "Artwork_frame",
        "rotation": [(tilt / 2.0).sin(), 0.0, 0.0, (tilt / 2.0).cos()],
        "translation": translation,
        "children": children,
    }));
    doc["scenes"][scene]["nodes"] = json!([root]);
    doc["asset"]["generator"] = json!(OAK_FRAME_GENERATOR);

    write_glb(&doc, &bin)
}

/// 板と台座を組み立てたアクリルスタンドの GLB
fn build_stand_glb(texture_jpeg: &[u8], width: u32, height: u32) -> Vec<u8> {
    let parts = stand_parts(width, height);
    let style = Style::Stand;

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

    write_glb(&document, &bin)
}

/// glTF の JSON と BIN から GLB を書く (BIN は 4 バイトにそろえてあること)
fn write_glb(document: &Value, bin: &[u8]) -> Vec<u8> {
    let mut json_bytes = serde_json::to_vec(document).expect("glTF JSON serialization");
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
    out.extend_from_slice(bin);
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

// =============================
// 大きさを測る (配置の判定に使う作品の実寸)
// =============================

/// ノードの入れ子の深さの上限 (壊れた GLB で無限に潜らないため)
const MAX_NODE_DEPTH: usize = 64;
/// これより薄い軸がある GLB は測れなかったことにする (m)
const MIN_SIDE: f64 = 1e-3;

/// 4 × 4 の行列 (m[行][列])
type Matrix = [[f64; 4]; 4];

const IDENTITY: Matrix = [[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]];

/// GLB の幅・高さ・奥行き (m) を測る。
///
/// シーンのノードをたどり、各 primitive の POSITION の min / max (8 頂点) をノードの変換で動かした箱の大きさ。
/// 頂点のデータは読まない (JSON のチャンクだけを見る)。min / max が無い・normalized の GLB や、
/// 薄すぎる (1 mm 未満) GLB は Err。呼び出し側は Err を「寸法不明」(NULL) として扱う
pub fn measure_glb(data: &[u8]) -> Result<[f64; 3], String> {
    validate_glb(data)?;
    if data.len() < 20 {
        return Err("GLB に JSON のチャンクがありません".into());
    }
    let json_len = u32::from_le_bytes([data[12], data[13], data[14], data[15]]) as usize;
    if json_len.checked_add(20).is_none_or(|end| end > data.len()) {
        return Err("GLB の JSON のチャンクが途中で切れています".into());
    }
    if &data[16..20] != b"JSON" {
        return Err("GLB の最初のチャンクが JSON ではありません".into());
    }
    let doc: Value =
        serde_json::from_slice(&data[20..20 + json_len]).map_err(|e| format!("GLB の JSON を読めません: {e}"))?;

    let nodes = doc.get("nodes").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
    let roots: Vec<u64> = match doc.get("scenes").and_then(Value::as_array) {
        Some(scenes) => {
            let index = doc.get("scene").and_then(Value::as_u64).unwrap_or(0) as usize;
            let scene = scenes.get(index).ok_or("GLB に scene がありません")?;
            scene.get("nodes").and_then(Value::as_array).map_or(Vec::new(), |n| n.iter().filter_map(Value::as_u64).collect())
        }
        // scenes が無ければ、親を持たないノードを全部たどる
        None => {
            let children: Vec<u64> = nodes
                .iter()
                .filter_map(|n| n.get("children").and_then(Value::as_array))
                .flatten()
                .filter_map(Value::as_u64)
                .collect();
            (0..nodes.len() as u64).filter(|i| !children.contains(i)).collect()
        }
    };

    let mut bounds = [[f64::INFINITY; 3], [f64::NEG_INFINITY; 3]];
    for root in roots {
        visit_node(&doc, nodes, root, &IDENTITY, 0, &mut bounds)?;
    }
    let [min, max] = bounds;
    let size = [max[0] - min[0], max[1] - min[1], max[2] - min[2]];
    if size.iter().any(|v| !v.is_finite() || *v < MIN_SIDE) {
        return Err(format!("GLB の大きさを測れません ({size:?})"));
    }
    Ok(size)
}

/// ノードとその子をたどって、primitive の箱を bounds ([min, max]) に足す
fn visit_node(
    doc: &Value,
    nodes: &[Value],
    index: u64,
    parent: &Matrix,
    depth: usize,
    bounds: &mut [[f64; 3]; 2],
) -> Result<(), String> {
    if depth > MAX_NODE_DEPTH {
        return Err("GLB のノードの入れ子が深すぎます".into());
    }
    let node = nodes.get(index as usize).ok_or_else(|| format!("GLB にノード {index} がありません"))?;
    let world = multiply(parent, &local_matrix(node)?);

    if let Some(mesh) = node.get("mesh").and_then(Value::as_u64) {
        let primitives = doc
            .pointer(&format!("/meshes/{mesh}/primitives"))
            .and_then(Value::as_array)
            .ok_or_else(|| format!("GLB にメッシュ {mesh} がありません"))?;
        for primitive in primitives {
            let [min, max] = position_bounds(doc, primitive)?;
            // 箱の 8 頂点をワールド座標に動かす
            for corner in 0..8 {
                let p = [
                    if corner & 1 == 0 { min[0] } else { max[0] },
                    if corner & 2 == 0 { min[1] } else { max[1] },
                    if corner & 4 == 0 { min[2] } else { max[2] },
                ];
                let q = transform(&world, p);
                for k in 0..3 {
                    bounds[0][k] = bounds[0][k].min(q[k]);
                    bounds[1][k] = bounds[1][k].max(q[k]);
                }
            }
        }
    }
    for child in node.get("children").and_then(Value::as_array).into_iter().flatten() {
        let child = child.as_u64().ok_or("GLB のノードの children が正しくありません")?;
        visit_node(doc, nodes, child, &world, depth + 1, bounds)?;
    }
    Ok(())
}

/// primitive の POSITION の min / max。無い・normalized (量子化) のときは測れない
fn position_bounds(doc: &Value, primitive: &Value) -> Result<[[f64; 3]; 2], String> {
    let accessor = primitive
        .pointer("/attributes/POSITION")
        .and_then(Value::as_u64)
        .and_then(|i| doc.pointer(&format!("/accessors/{i}")))
        .ok_or("GLB の primitive に POSITION がありません")?;
    if accessor.get("normalized").and_then(Value::as_bool) == Some(true) {
        return Err("GLB の POSITION が normalized なので測れません".into());
    }
    let vec3 = |key: &str| -> Option<[f64; 3]> {
        let values: Vec<f64> = accessor.get(key)?.as_array()?.iter().filter_map(Value::as_f64).collect();
        <[f64; 3]>::try_from(values).ok()
    };
    match (vec3("min"), vec3("max")) {
        (Some(min), Some(max)) => Ok([min, max]),
        _ => Err("GLB の POSITION に min / max がありません".into()),
    }
}

/// ノードの変換。matrix (列優先) か、translation · rotation · scale
fn local_matrix(node: &Value) -> Result<Matrix, String> {
    let numbers = |key: &str, len: usize| -> Result<Option<Vec<f64>>, String> {
        let Some(value) = node.get(key) else { return Ok(None) };
        let list: Vec<f64> = value.as_array().into_iter().flatten().filter_map(Value::as_f64).collect();
        if list.len() != len {
            return Err(format!("GLB のノードの {key} が正しくありません"));
        }
        Ok(Some(list))
    };
    if let Some(m) = numbers("matrix", 16)? {
        // glTF の matrix は列優先 (m[列 * 4 + 行])
        let mut out = IDENTITY;
        for (row, line) in out.iter_mut().enumerate() {
            for (col, cell) in line.iter_mut().enumerate() {
                *cell = m[col * 4 + row];
            }
        }
        return Ok(out);
    }
    let t = numbers("translation", 3)?.unwrap_or(vec![0.0; 3]);
    // 四元数は [x, y, z, w]
    let r = numbers("rotation", 4)?.unwrap_or(vec![0.0, 0.0, 0.0, 1.0]);
    let s = numbers("scale", 3)?.unwrap_or(vec![1.0; 3]);
    let (x, y, z, w) = (r[0], r[1], r[2], r[3]);
    let rotation = [
        [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w)],
        [2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)],
        [2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y)],
    ];
    let mut out = IDENTITY;
    for row in 0..3 {
        for col in 0..3 {
            out[row][col] = rotation[row][col] * s[col];
        }
        out[row][3] = t[row];
    }
    Ok(out)
}

fn multiply(a: &Matrix, b: &Matrix) -> Matrix {
    let mut out = [[0.0; 4]; 4];
    for (row, line) in out.iter_mut().enumerate() {
        for (col, cell) in line.iter_mut().enumerate() {
            *cell = (0..4).map(|k| a[row][k] * b[k][col]).sum();
        }
    }
    out
}

fn transform(m: &Matrix, p: [f64; 3]) -> [f64; 3] {
    let row = |r: usize| m[r][0] * p[0] + m[r][1] * p[1] + m[r][2] * p[2] + m[r][3];
    [row(0), row(1), row(2)]
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

    /// 単色の JPEG (幅 × 高さ)
    fn jpeg(width: u32, height: u32) -> Vec<u8> {
        media::encode_jpeg(&image::DynamicImage::new_rgb8(width, height), 85)
    }

    #[test]
    fn builds_valid_glb_for_both_styles() {
        let photo = jpeg(800, 600);
        for style in [Style::Frame, Style::Stand] {
            let glb = build_artwork_glb(&photo, 800, 600, style);
            validate_glb(&glb).unwrap();
            let doc = parse(&glb);
            for view in doc["bufferViews"].as_array().unwrap() {
                assert_eq!(view["byteOffset"].as_u64().unwrap_or(0) % 4, 0);
            }
            let bin_len = doc["buffers"][0]["byteLength"].as_u64().unwrap() as usize;
            assert_eq!(bin_len % 4, 0);
            let (_, bin) = split_glb(&glb).unwrap();
            assert_eq!(bin.len(), bin_len);
        }
        let stand = parse(&build_artwork_glb(&photo, 800, 600, Style::Stand));
        assert!(stand["meshes"][0]["primitives"].as_array().unwrap().len() >= 4);
    }

    #[test]
    fn frame_puts_the_photo_on_the_photo_surface() {
        let doc = parse(&build_artwork_glb(&jpeg(800, 600), 800, 600, Style::Frame));
        assert_eq!(doc["asset"]["generator"], OAK_FRAME_GENERATOR);
        let nodes = doc["nodes"].as_array().unwrap();
        let photo = nodes.iter().find(|n| n["name"] == "Photo_Surface").unwrap();
        let material = doc["meshes"][photo["mesh"].as_u64().unwrap() as usize]["primitives"][0]["material"].as_u64().unwrap();
        let texture = doc["materials"][material as usize]["pbrMetallicRoughness"]["baseColorTexture"]["index"].as_u64().unwrap();
        let image = doc["textures"][texture as usize]["source"].as_u64().unwrap();
        assert_eq!(doc["images"][image as usize]["name"], "Photo");
        // 額縁の 3 つのノードは、傾けて動かす親のノードの下
        let scene = doc["scenes"][0]["nodes"].as_array().unwrap();
        assert_eq!(scene.len(), 1);
        assert_eq!(doc["nodes"][scene[0].as_u64().unwrap() as usize]["children"].as_array().unwrap().len(), 3);
    }

    #[test]
    fn frame_is_chosen_by_the_photo_shape() {
        assert_eq!(oak_frame_for(800, 600).0, 1.5);
        assert_eq!(oak_frame_for(1000, 1000).0, 1.0);
        assert_eq!(oak_frame_for(1100, 1000).0, 1.0);
        assert_eq!(oak_frame_for(300, 900).0, 2.0 / 3.0);
    }

    #[test]
    fn photo_is_cropped_to_the_frame_without_stretching() {
        let size = |bytes: &[u8]| image::load_from_memory(bytes).unwrap().dimensions();
        assert_eq!(size(&crop_to_aspect(&jpeg(400, 100), 1.5)), (150, 100));
        assert_eq!(size(&crop_to_aspect(&jpeg(100, 400), 2.0 / 3.0)), (100, 150));
        assert_eq!(size(&crop_to_aspect(&jpeg(300, 200), 1.5)), (300, 200));
    }

    #[test]
    fn art_size_keeps_aspect() {
        assert_eq!(art_size(400, 200, 1.0), (1.0, 0.5));
        assert_eq!(art_size(200, 400, 1.0), (0.5, 1.0));
    }

    fn close3(a: [f64; 3], b: [f64; 3], tolerance: f64) -> bool {
        a.iter().zip(b).all(|(x, y)| (x - y).abs() < tolerance)
    }

    #[test]
    fn measures_generated_glb() {
        let fake_jpeg = vec![0xFFu8, 0xD8, 0xFF, 0xD9];
        // 額縁: 横長の額縁 (外寸 34.8 × 24.8 cm、厚さ 2.2 cm) を 8° 傾けた箱
        let frame = measure_glb(&build_artwork_glb(&jpeg(800, 600), 800, 600, Style::Frame)).unwrap();
        let (sin, cos) = OAK_FRAME_TILT_DEG.to_radians().sin_cos();
        let expected = [0.348, 0.248 * cos + 0.022 * sin, 0.248 * sin + 0.022 * cos];
        assert!(close3(frame, expected, 1e-5), "{frame:?}");
        // スタンド: 幅は台座 (w/2 + 0.08 の楕円)、高さは板の上端、奥行きは台座の 0.44
        let stand = measure_glb(&build_artwork_glb(&fake_jpeg, 800, 600, Style::Stand)).unwrap();
        assert!(close3(stand, [1.16, 0.845, 0.44], 1e-5), "{stand:?}");
        // 縦長の工作は台座の幅が 0.56 で止まる
        let tall = measure_glb(&build_artwork_glb(&fake_jpeg, 300, 900, Style::Stand)).unwrap();
        assert!(close3(tall, [0.56, 0.025 + 0.035 + 1.0 + 0.035, 0.44], 1e-5), "{tall:?}");
    }

    /// JSON のチャンクだけの GLB (measure_glb は頂点のデータを読まない)
    fn glb_of(doc: Value) -> Vec<u8> {
        let mut json_bytes = serde_json::to_vec(&doc).unwrap();
        while json_bytes.len() % 4 != 0 {
            json_bytes.push(b' ');
        }
        let mut out = Vec::new();
        out.extend_from_slice(b"glTF");
        out.extend_from_slice(&2u32.to_le_bytes());
        out.extend_from_slice(&((20 + json_bytes.len()) as u32).to_le_bytes());
        out.extend_from_slice(&(json_bytes.len() as u32).to_le_bytes());
        out.extend_from_slice(b"JSON");
        out.extend_from_slice(&json_bytes);
        out
    }

    /// 1 辺 [min, max] の箱のメッシュ 1 つと、nodes の GLB
    fn box_glb(min: [f64; 3], max: [f64; 3], scenes: Option<Value>, nodes: Value) -> Vec<u8> {
        let mut doc = json!({
            "asset": { "version": "2.0" },
            "nodes": nodes,
            "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0 } }] }],
            "accessors": [{ "componentType": 5126, "count": 8, "type": "VEC3", "min": min, "max": max }],
        });
        if let Some(scenes) = scenes {
            doc["scenes"] = scenes;
        }
        glb_of(doc)
    }

    #[test]
    fn measures_node_transforms() {
        // T·R·S: x を 2 倍してから Y まわりに 90° 回す → 幅と奥行きが入れ替わる。平行移動は大きさに効かない
        let half = std::f64::consts::FRAC_1_SQRT_2;
        let trs = box_glb(
            [-0.5, 0.0, -0.1],
            [0.5, 1.0, 0.1],
            Some(json!([{ "nodes": [0] }])),
            json!([{ "mesh": 0, "translation": [1, 2, 3], "rotation": [0, half, 0, half], "scale": [2, 1, 1] }]),
        );
        let size = measure_glb(&trs).unwrap();
        assert!(close3(size, [0.2, 1.0, 2.0], 1e-9), "{size:?}");

        // matrix は列優先: Z まわりに 90° 回して x に 4 動かした箱と、動かさない箱を、親で 0.5 倍すると [2, 1, 1]。
        // 行優先で読むと回転が逆で平行移動が消え、[1, 2, 1] になる
        let matrix = [0, 1, 0, 0, -1, 0, 0, 0, 0, 0, 1, 0, 4, 0, 0, 1];
        let nodes = json!([
            { "children": [1, 2], "scale": [0.5, 0.5, 0.5] },
            { "mesh": 0 },
            { "mesh": 0, "matrix": matrix },
        ]);
        let with_matrix = box_glb([0.0; 3], [2.0; 3], Some(json!([{ "nodes": [0] }])), nodes.clone());
        let size = measure_glb(&with_matrix).unwrap();
        assert!(close3(size, [2.0, 1.0, 1.0], 1e-9), "{size:?}");
        // scenes が無ければ、親を持たないノード (0) からたどる
        let size = measure_glb(&box_glb([0.0; 3], [2.0; 3], None, nodes)).unwrap();
        assert!(close3(size, [2.0, 1.0, 1.0], 1e-9), "{size:?}");
    }

    #[test]
    fn measures_atelier_models_like_the_kit_catalog() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("static").join("atelier");
        let Ok(text) = std::fs::read_to_string(dir.join("catalog.json")) else {
            // フォルダが無い構成でも動くようにしてある (seed は何もしない)
            return;
        };
        let items: Vec<Value> = serde_json::from_str(&text).unwrap();
        assert_eq!(items.len(), 33);
        for item in items {
            let model = item["model"].as_str().unwrap();
            let expected: Vec<f64> = item["dimensionsMeters"].as_array().unwrap().iter().filter_map(Value::as_f64).collect();
            let size = measure_glb(&std::fs::read(dir.join(model)).unwrap()).unwrap();
            assert!(close3(size, expected.clone().try_into().unwrap(), 1e-3), "{model}: {size:?} != {expected:?}");
        }
    }

    #[test]
    fn measure_rejects_bad_glb() {
        let good = box_glb([0.0; 3], [1.0; 3], None, json!([{ "mesh": 0 }]));
        assert!(measure_glb(&good).is_ok());
        // 短すぎる・形式が違う・JSON の長さが中身より長い・最初のチャンクが JSON でない
        assert!(measure_glb(b"glTF").is_err());
        assert!(measure_glb(&[b"GLTF".as_slice(), &good[4..]].concat()).is_err());
        let mut long = good.clone();
        long[12..16].copy_from_slice(&(good.len() as u32).to_le_bytes());
        assert!(measure_glb(&long).is_err());
        let mut bin = good.clone();
        bin[16..20].copy_from_slice(b"BIN\0");
        assert!(measure_glb(&bin).is_err());
        let mut broken = good.clone();
        broken[20] = b'x';
        assert!(measure_glb(&broken).is_err());
        // メッシュが無い・薄すぎる
        assert!(measure_glb(&box_glb([0.0; 3], [1.0; 3], None, json!([{}]))).is_err());
        assert!(measure_glb(&box_glb([0.0; 3], [1.0, 1.0, 0.0005], None, json!([{ "mesh": 0 }]))).is_err());
        // min / max が無い・normalized
        let doc = |accessor: Value| {
            glb_of(json!({
                "nodes": [{ "mesh": 0 }],
                "meshes": [{ "primitives": [{ "attributes": { "POSITION": 0 } }] }],
                "accessors": [accessor],
            }))
        };
        assert!(measure_glb(&doc(json!({ "count": 8, "type": "VEC3" }))).is_err());
        let normalized = json!({ "count": 8, "type": "VEC3", "normalized": true, "min": [0, 0, 0], "max": [100, 100, 100] });
        assert!(measure_glb(&doc(normalized)).is_err());
        // 自分を子に持つノード (入れ子が深すぎる)
        let looped = box_glb([0.0; 3], [1.0; 3], Some(json!([{ "nodes": [0] }])), json!([{ "mesh": 0, "children": [0] }]));
        assert!(measure_glb(&looped).is_err());
    }
}
