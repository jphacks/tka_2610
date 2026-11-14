//! 「すべて」の鑑賞用配置。年齢別の保存済み配置には書き込まない。
//! 初期配置の空き → 家具を追加 → 次の階、の順。後の作品も必ず下の階から試す。
use crate::{
    home::{self, ArtSize, Layout, Sizes},
    home_api::RoomInfo,
};
use uuid::Uuid;

pub fn pack(artworks: &[(Uuid, Option<ArtSize>)]) -> Result<Vec<Layout>, String> {
    let sizes: Sizes = artworks
        .iter()
        .filter_map(|(id, size)| size.map(|s| (*id, s)))
        .collect();
    let mut floors: Vec<Layout> = Vec::new();
    for (id, size) in artworks {
        let mut placed = false;
        for layout in &mut floors {
            if let Some(objects) = place(layout, &sizes, *id, size.as_ref()) {
                layout.objects.extend(objects);
                placed = true;
                break;
            }
        }
        if placed {
            continue;
        }
        let mut next = home::default_layout();
        let objects = place(&next, &sizes, *id, size.as_ref())
            .ok_or_else(|| format!("作品 {id} を空のおへやにも置けませんでした"))?;
        next.objects.extend(objects);
        floors.push(next);
    }
    Ok(floors)
}

// 自動配置は再取得のたびに作り直すので、家具・作品の表示用 id も作品 id から固定する。
fn place(layout: &Layout, sizes: &Sizes, id: Uuid, size: Option<&ArtSize>) -> Option<Vec<home::LayoutObject>> {
    let mut objects = home::place_or_furnish(layout, sizes, id, size)?;
    let added = objects.iter().find_map(|object| match object {
        home::LayoutObject::Furniture(f) => Some(f.id.clone()),
        _ => None,
    });
    for object in &mut objects {
        match object {
            home::LayoutObject::Furniture(f) => f.id = format!("all-furniture-{id}"),
            home::LayoutObject::Artwork(a) => {
                a.id = format!("all-art-{id}");
                if added.is_some() && a.parent_id == added {
                    a.parent_id = Some(format!("all-furniture-{id}"));
                }
            }
        }
    }
    Some(objects)
}

/// 保存されたおへやと区別する表示専用の識別子。age = -1 は DB には書かない。
pub fn room_info(floor: usize) -> RoomInfo {
    RoomInfo {
        id: Uuid::new_v5(&Uuid::NAMESPACE_URL, format!("memoria:all-ages:{floor}").as_bytes()),
        age: -1,
        floor: floor as i16,
        name: if floor == 0 {
            "すべてのおへや".into()
        } else {
            format!("すべてのおへや {}", floor + 1)
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use home::{DoorPolicy, LayoutObject};
    use std::collections::HashSet;

    fn artworks(n: usize) -> Vec<(Uuid, Option<ArtSize>)> {
        (1..=n).map(|i| (Uuid::from_u128(i as u128), None)).collect()
    }

    #[test]
    fn adds_furniture_before_a_second_floor() {
        let arts = artworks(33);
        let floors = pack(&arts).unwrap();
        assert_eq!(floors.len(), 1);
        assert_eq!(floors[0].artworks().count(), 33);
        let furniture = |l: &Layout| {
            l.objects
                .iter()
                .filter(|o| matches!(o, LayoutObject::Furniture(_)))
                .count()
        };
        assert!(furniture(&floors[0]) > furniture(&home::default_layout()));
        home::check_placement(&floors[0], &Sizes::new(), DoorPolicy::Ignore).unwrap();
    }

    #[test]
    fn fills_lower_floors_before_adding_another_and_keeps_every_artwork() {
        let arts = artworks(150);
        let floors = pack(&arts).unwrap();
        assert!(floors.len() > 1);
        let mut seen = HashSet::new();
        for (i, floor) in floors.iter().enumerate() {
            assert!(floor.objects.len() <= 120);
            home::check_placement(floor, &Sizes::new(), DoorPolicy::Ignore).unwrap();
            for art in floor.artworks() {
                assert!(seen.insert(art.artwork_id));
            }
            if let Some(next) = floors.get(i + 1) {
                let first = next.artworks().next().unwrap();
                assert!(home::place_or_furnish(floor, &Sizes::new(), first.artwork_id, None).is_none());
            }
        }
        assert_eq!(seen, arts.iter().map(|(id, _)| *id).collect());
        assert_eq!(
            serde_json::to_value(&floors).unwrap(),
            serde_json::to_value(pack(&arts).unwrap()).unwrap()
        );
    }

    #[test]
    fn empty_collection_has_no_extra_floor() {
        assert!(pack(&[]).unwrap().is_empty());
    }
}
