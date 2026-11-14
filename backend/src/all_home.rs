//! 「すべて」の保存済み配置。年齢別の配置・作品の展示先の列とは独立している。
//! 新作だけ空きへ足し、模様替えで外した作品は hidden に記録して勝手に戻さない。
use std::collections::BTreeSet;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::home::{self, ArtSize, DoorPolicy, Layout, LayoutObject, Sizes};

type Artworks = [(Uuid, Option<ArtSize>)];

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct AllHome {
    pub floors: Vec<Layout>,
    #[serde(default)]
    pub hidden: BTreeSet<Uuid>,
}

fn sizes(artworks: &Artworks) -> Sizes {
    artworks
        .iter()
        .filter_map(|(id, size)| size.map(|s| (*id, s)))
        .collect()
}

impl AllHome {
    /// 削除済み・寸法変更で置けなくなった作品を整理し、新作を下の階の空きから飾る。
    /// 空になった階も、家具・テーマと階番号を保つため残す。
    pub fn reconcile(&mut self, artworks: &Artworks) -> Result<(), String> {
        let existing: BTreeSet<_> = artworks.iter().map(|(id, _)| *id).collect();
        self.hidden.retain(|id| existing.contains(id));
        let sizes = sizes(artworks);
        let mut placed = BTreeSet::new();
        for floor in &mut self.floors {
            floor.objects.retain(|o| match o {
                LayoutObject::Artwork(a) => existing.contains(&a.artwork_id),
                _ => true,
            });
            let raw = serde_json::to_value(&*floor).map_err(|e| e.to_string())?;
            let parsed = home::parse_layout(raw.clone())?;
            *floor = if home::check_placement(&parsed, &sizes, DoorPolicy::Ignore).is_ok() {
                parsed
            } else {
                // 配置全体は初期化しない。置けない作品だけ外し、このあと置き直す。
                home::repair_layout(raw, &sizes)?.0
            };
            for art in floor.artworks() {
                if !placed.insert(art.artwork_id) {
                    return Err("同じ作品が複数のおへやに飾られています".into());
                }
            }
        }
        self.hidden.retain(|id| !placed.contains(id));
        if self.floors.is_empty() {
            self.floors.push(home::default_layout());
        }
        for (id, size) in artworks {
            if placed.contains(id) || self.hidden.contains(id) {
                continue;
            }
            let mut added = false;
            for floor in &mut self.floors {
                if let Some(objects) = crate::all_ages::place(floor, &sizes, *id, size.as_ref()) {
                    floor.objects.extend(objects);
                    added = true;
                    break;
                }
            }
            if !added {
                let mut floor = home::default_layout();
                let objects = crate::all_ages::place(&floor, &sizes, *id, size.as_ref())
                    .ok_or_else(|| format!("作品 {id} を空のおへやにも置けませんでした"))?;
                floor.objects.extend(objects);
                self.floors.push(floor);
            }
        }
        Ok(())
    }

    /// 保存先の1階分だけを変更する。年齢は制限しないが、作品の存在・重複・置き方は検証する。
    pub fn save_floor(
        &mut self,
        floor: usize,
        layout: Layout,
        artworks: &Artworks,
    ) -> Result<(), String> {
        let before = self.floors.get(floor).ok_or("そのおへやはありません")?;
        let existing: BTreeSet<_> = artworks.iter().map(|(id, _)| *id).collect();
        let elsewhere: BTreeSet<_> = self
            .floors
            .iter()
            .enumerate()
            .filter(|(i, _)| *i != floor)
            .flat_map(|(_, l)| l.artworks().map(|a| a.artwork_id))
            .collect();
        let after: BTreeSet<_> = layout.artworks().map(|a| a.artwork_id).collect();
        if !after.is_subset(&existing) {
            return Err("配置に、登録されていない作品が含まれています".into());
        }
        if !after.is_disjoint(&elsewhere) {
            return Err("別の「すべてのおへや」に飾られている作品が含まれています".into());
        }
        let moved = home::moved_ids(before, &layout);
        home::check_placement(&layout, &sizes(artworks), DoorPolicy::OnlyMoved(&moved))?;
        self.hidden.extend(
            before
                .artworks()
                .map(|a| a.artwork_id)
                .filter(|id| !after.contains(id)),
        );
        self.hidden.retain(|id| !after.contains(id));
        self.floors[floor] = layout;
        Ok(())
    }

    /// 外した作品を指定の階へ再び飾る。満杯ならほかの階へ移さず None を返す。
    pub fn display(&mut self, floor: usize, id: Uuid, artworks: &Artworks) -> Result<bool, String> {
        let size = artworks
            .iter()
            .find(|(key, _)| *key == id)
            .ok_or("作品が見つかりません")?
            .1;
        let target = self.floors.get(floor).ok_or("そのおへやはありません")?;
        if target.artworks().any(|a| a.artwork_id == id) {
            return Ok(true);
        }
        if self
            .floors
            .iter()
            .any(|l| l.artworks().any(|a| a.artwork_id == id))
        {
            return Err("別の「すべてのおへや」に飾られています".into());
        }
        let Some(objects) = crate::all_ages::place(target, &sizes(artworks), id, size.as_ref())
        else {
            return Ok(false);
        };
        let mut layout = target.clone();
        layout.objects.extend(objects);
        self.save_floor(floor, layout, artworks)?;
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn arts(n: usize) -> Vec<(Uuid, Option<ArtSize>)> {
        (1..=n)
            .map(|id| (Uuid::from_u128(id as u128), None))
            .collect()
    }
    fn state(n: usize) -> AllHome {
        let mut home = AllHome::default();
        home.reconcile(&arts(n)).unwrap();
        home
    }
    #[test]
    fn first_load_matches_old_all_ages_packing() {
        let home = state(33);
        assert_eq!(home.floors, crate::all_ages::pack(&arts(33)).unwrap());
        for layout in home.floors {
            assert_eq!(
                home::parse_layout(serde_json::to_value(&layout).unwrap()).unwrap(),
                layout
            );
        }
    }
    #[test]
    fn decorations_and_positions_survive_reload_and_new_artwork() {
        let mut home = state(3);
        let mut layout = home.floors[0].clone();
        layout.rooms.hub.wall = "oak".into();
        home.save_floor(0, layout.clone(), &arts(3)).unwrap();
        let mut restored: AllHome =
            serde_json::from_value(serde_json::to_value(&home).unwrap()).unwrap();
        restored.reconcile(&arts(4)).unwrap();
        assert_eq!(restored.floors[0].rooms, layout.rooms);
        for object in layout.objects {
            assert!(restored.floors[0].objects.contains(&object));
        }
        assert_eq!(restored.floors[0].artworks().count(), 4);
    }
    #[test]
    fn removed_artwork_stays_hidden_and_can_be_added_back() {
        let mut home = state(3);
        let mut layout = home.floors[0].clone();
        layout
            .objects
            .retain(|o| !matches!(o, LayoutObject::Artwork(a) if a.artwork_id == arts(3)[0].0));
        home.save_floor(0, layout, &arts(3)).unwrap();
        home.reconcile(&arts(4)).unwrap();
        assert_eq!(home.floors[0].artworks().count(), 3);
        assert!(home.display(0, arts(3)[0].0, &arts(4)).unwrap());
        assert!(home.hidden.is_empty());
        assert_eq!(home.floors[0].artworks().count(), 4);
    }
    #[test]
    fn deletion_cleans_artworks_and_hidden_without_resetting_furniture() {
        let mut home = state(3);
        let mut layout = home.floors[0].clone();
        layout
            .objects
            .retain(|o| matches!(o, LayoutObject::Furniture(_)));
        home.save_floor(0, layout.clone(), &arts(3)).unwrap();
        home.reconcile(&[]).unwrap();
        assert_eq!(home.floors, vec![layout]);
        assert!(home.hidden.is_empty());
        let mut shown = state(3);
        shown.reconcile(&[]).unwrap();
        assert_eq!(shown.floors[0].artworks().count(), 0);
    }
    #[test]
    fn saving_one_floor_preserves_other_floor_and_rejects_duplicate_artwork() {
        let mut home = state(150);
        let upper = home.floors[1].clone();
        let mut lower = home.floors[0].clone();
        lower.rooms.hub.wall = "oak".into();
        home.save_floor(0, lower, &arts(150)).unwrap();
        assert_eq!(home.floors[1], upper);
        assert!(
            home.save_floor(0, upper, &arts(150))
                .unwrap_err()
                .contains("別の")
        );
    }
    #[test]
    fn unknown_artworks_and_invalid_placement_do_not_mutate_state() {
        let mut home = state(3);
        let before = serde_json::to_value(&home).unwrap();
        let mut bad = home.floors[0].clone();
        for object in &mut bad.objects {
            if let LayoutObject::Artwork(a) = object {
                a.artwork_id = Uuid::new_v4();
                break;
            }
        }
        assert!(home.save_floor(0, bad, &arts(3)).is_err());
        let mut bad = home.floors[0].clone();
        for object in &mut bad.objects {
            if let LayoutObject::Furniture(f) = object {
                f.position[0] = 99.0;
                break;
            }
        }
        assert!(home.save_floor(0, bad, &arts(3)).is_err());
        assert_eq!(serde_json::to_value(&home).unwrap(), before);
    }
    #[test]
    fn empty_collection_can_be_decorated() {
        let mut home = state(0);
        let mut layout = home.floors[0].clone();
        layout.rooms.hub.wall = "oak".into();
        home.save_floor(0, layout.clone(), &[]).unwrap();
        home.reconcile(&[]).unwrap();
        assert_eq!(home.floors, vec![layout]);
    }
}
