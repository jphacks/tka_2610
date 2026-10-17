//! 博物館のレイアウト (展示台・部屋・フロア) と展示位置の決定ロジック。
//!
//! 座標は Unity の MuseumManifest.json / 博物館GLB と同じ (メートル, Y-up)。
//! Web(three.js) と Unity の両方がこの値をそのまま使う。

use std::collections::HashSet;

use serde::Serialize;

pub struct SlotDef {
    pub id: &'static str,
    /// 展示台の天板中心
    pub position: [f32; 3],
    /// Unity シーン上の展示台自身の Y 回転
    pub unity_rotation: f32,
    /// 博物館GLB(Web表示)に含まれる展示台か。false は Unity の別館のみ
    pub in_main_model: bool,
}

pub const SLOTS: &[SlotDef] = &[
    SlotDef { id: "SLOT_001", position: [0.00, 1.08, -6.10], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_002", position: [-3.95, 1.08, -0.70], unity_rotation: 180.0, in_main_model: true },
    SlotDef { id: "SLOT_003", position: [3.95, 1.08, -0.70], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_004", position: [-4.00, 1.08, -10.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_005", position: [4.00, 1.08, -10.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_006", position: [-9.65, 1.08, -7.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_007", position: [-9.65, 1.08, -2.10], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_008", position: [-9.65, 1.08, 6.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_009", position: [-9.65, 1.08, 11.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_010", position: [9.65, 1.08, -7.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_011", position: [9.65, 1.08, -2.10], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_012", position: [9.65, 1.08, 6.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_013", position: [9.65, 1.08, 11.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_014", position: [-3.80, 1.08, 12.25], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_015", position: [3.80, 1.08, 12.25], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_016", position: [-9.35, 5.30, -8.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_017", position: [-9.35, 5.30, -0.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_018", position: [-9.35, 5.30, 7.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_019", position: [9.35, 5.30, -8.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_020", position: [9.35, 5.30, -0.50], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_021", position: [9.35, 5.30, 7.00], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_022", position: [-4.00, 5.30, 12.40], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_023", position: [4.00, 5.30, 12.40], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_024", position: [0.00, 5.30, -12.45], unity_rotation: 0.0, in_main_model: true },
    SlotDef { id: "SLOT_025", position: [-17.10, 1.08, 0.20], unity_rotation: 0.0, in_main_model: false },
    SlotDef { id: "SLOT_026", position: [-17.10, 1.08, 3.00], unity_rotation: 0.0, in_main_model: false },
    SlotDef { id: "SLOT_027", position: [-17.10, 1.08, 5.80], unity_rotation: 0.0, in_main_model: false },
    SlotDef { id: "SLOT_028", position: [17.10, 1.08, 0.20], unity_rotation: 0.0, in_main_model: false },
    SlotDef { id: "SLOT_029", position: [17.10, 1.08, 3.00], unity_rotation: 0.0, in_main_model: false },
    SlotDef { id: "SLOT_030", position: [17.10, 1.08, 5.80], unity_rotation: 0.0, in_main_model: false },
];

pub struct RoomDef {
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub categories: &'static [&'static str],
    pub slots: &'static [&'static str],
    /// 別館 (Unity のみに存在)
    pub annex: bool,
}

pub const ROOMS: &[RoomDef] = &[
    RoomDef {
        id: "paint",
        name: "絵画の部屋",
        description: "おえかき・絵の具の作品",
        categories: &["drawing"],
        slots: &["SLOT_006", "SLOT_007", "SLOT_008", "SLOT_009", "SLOT_016", "SLOT_017", "SLOT_018"],
        annex: false,
    },
    RoomDef {
        id: "craft",
        name: "工作の部屋",
        description: "ねんど・工作の立体作品",
        categories: &["craft"],
        slots: &["SLOT_010", "SLOT_011", "SLOT_012", "SLOT_013", "SLOT_019", "SLOT_020", "SLOT_021"],
        annex: false,
    },
    RoomDef {
        id: "memory",
        name: "思い出の部屋",
        description: "写真やたからもの",
        categories: &["photo", "other"],
        slots: &[
            "SLOT_001", "SLOT_002", "SLOT_003", "SLOT_004", "SLOT_005",
            "SLOT_014", "SLOT_015", "SLOT_022", "SLOT_023", "SLOT_024",
        ],
        annex: false,
    },
    RoomDef {
        id: "annex",
        name: "別館",
        description: "本館がいっぱいになったときの展示室",
        categories: &[],
        slots: &["SLOT_025", "SLOT_026", "SLOT_027", "SLOT_028", "SLOT_029", "SLOT_030"],
        annex: true,
    },
];

pub fn slot(id: &str) -> Option<&'static SlotDef> {
    SLOTS.iter().find(|s| s.id == id)
}

pub fn room_of_slot(slot_id: &str) -> Option<&'static RoomDef> {
    ROOMS.iter().find(|r| r.slots.contains(&slot_id))
}

pub fn floor_of(slot: &SlotDef) -> &'static str {
    if slot.position[1] > 3.0 { "2F" } else { "1F" }
}

/// 作品の正面(+Z)を来館者が歩く通路側へ向けるワールド Y 回転 (度)。
///
/// Unity(左手系) と three.js(右手系) のどちらでも
/// yaw θ で +Z が (sinθ, 0, cosθ) を向くので、同じ値を使える。
pub fn world_yaw(slot: &SlotDef) -> f32 {
    let [x, _, z] = slot.position;

    if x.abs() < 0.5 {
        // 中央軸上: 正面側の壁際ならホール奥へ、それ以外は入口側へ
        return if z < -11.0 { 0.0 } else { 180.0 };
    }

    if x.abs() < 6.0 && z > 11.0 {
        // 奥の壁際はホールの方を向く
        return 180.0;
    }

    // 左右の展示台は中央通路の方を向く
    if x < 0.0 { 90.0 } else { -90.0 }
}

/// Unity の展示台はそれ自身が回転しているので、ローカル角度に直す
pub fn unity_local_yaw(slot: &SlotDef) -> f32 {
    (world_yaw(slot) - slot.unity_rotation).rem_euclid(360.0)
}

/// カテゴリに合った部屋の空き展示台 → 本館の空き → 別館 の順に探す
pub fn pick_slot(category: &str, occupied: &HashSet<String>) -> Option<&'static str> {
    let is_free = |id: &&'static str| !occupied.contains(*id);

    if let Some(room) = ROOMS
        .iter()
        .find(|r| !r.annex && r.categories.contains(&category))
    {
        if let Some(id) = room.slots.iter().copied().find(is_free) {
            return Some(id);
        }
    }

    for room in ROOMS.iter().filter(|r| !r.annex) {
        if let Some(id) = room.slots.iter().copied().find(is_free) {
            return Some(id);
        }
    }

    ROOMS
        .iter()
        .filter(|r| r.annex)
        .flat_map(|r| r.slots.iter().copied())
        .find(is_free)
}

pub fn category_label(category: &str) -> &'static str {
    match category {
        "drawing" => "絵画",
        "craft" => "工作",
        "photo" => "写真",
        _ => "その他",
    }
}

pub const CATEGORIES: &[&str] = &["drawing", "craft", "photo", "other"];

#[derive(Serialize)]
pub struct FloorView {
    pub id: &'static str,
    pub label: &'static str,
    /// 見取り図(カットアウェイ)で隠す GLB ノード名の接頭辞
    pub hide_prefixes: Vec<String>,
}

/// 見取り図のフロア別カットアウェイ設定
pub fn floor_views() -> Vec<FloorView> {
    let upper_slot_nodes = SLOTS
        .iter()
        .filter(|s| s.in_main_model && floor_of(s) == "2F")
        .flat_map(|s| [format!("DISPLAY_{}", s.id), format!("{}_PROP", s.id)]);

    let mut first: Vec<String> = [
        "Roof",
        "Mezzanine",
        "Exterior_West_Upper",
        "Exterior_East_Upper",
        "Exterior_Back_Upper",
        "Exterior_Front",
        "Furnishing_Upper",
        "LightingFixtures",
    ]
    .into_iter()
    .map(String::from)
    .collect();
    first.extend(upper_slot_nodes);

    let second = ["Roof", "Exterior_Front", "LightingFixtures"]
        .into_iter()
        .map(String::from)
        .collect();

    vec![
        FloorView { id: "1F", label: "1F", hide_prefixes: first },
        FloorView { id: "2F", label: "2F", hide_prefixes: second },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_slot_belongs_to_exactly_one_room() {
        for s in SLOTS {
            let n = ROOMS.iter().filter(|r| r.slots.contains(&s.id)).count();
            assert_eq!(n, 1, "{}", s.id);
        }
    }

    #[test]
    fn picks_room_for_category_then_overflows() {
        let mut occupied = HashSet::new();
        assert_eq!(pick_slot("drawing", &occupied), Some("SLOT_006"));
        assert_eq!(pick_slot("craft", &occupied), Some("SLOT_010"));
        assert_eq!(pick_slot("photo", &occupied), Some("SLOT_001"));

        for id in ROOMS[0].slots {
            occupied.insert(id.to_string());
        }
        // 絵画の部屋が満室なら他の部屋へ
        assert_eq!(pick_slot("drawing", &occupied), Some("SLOT_010"));

        for s in SLOTS.iter().filter(|s| s.in_main_model) {
            occupied.insert(s.id.to_string());
        }
        assert_eq!(pick_slot("drawing", &occupied), Some("SLOT_025"));

        for s in SLOTS {
            occupied.insert(s.id.to_string());
        }
        assert_eq!(pick_slot("drawing", &occupied), None);
    }

    #[test]
    fn side_slots_face_the_aisle() {
        assert_eq!(world_yaw(slot("SLOT_006").unwrap()), 90.0);
        assert_eq!(world_yaw(slot("SLOT_010").unwrap()), -90.0);
        assert_eq!(world_yaw(slot("SLOT_024").unwrap()), 0.0);
        // SLOT_002 は Unity 上で 180° 回転しているのでローカル角度で補正
        assert_eq!(unity_local_yaw(slot("SLOT_002").unwrap()), 270.0);
    }
}
