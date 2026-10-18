-- 部屋の壁を 3.2 m から 4.2 m に上げた版 (建物の GLB と、壁の家具を掛けられる高さ home.rs の WALL_HEIGHT)。表の形は変えない。
--
-- 古いビルドが VersionMissing(14) で止まるための番兵 (013 と同じ考え方)。古いサーバーは壁の高さを 3.2 m として判定するので、
-- 新しいサーバーで高く掛けた壁の家具のあるおへやを読むと配置を直せず (repair_layout は作品しか外せない)、初期配置に戻して保存してしまうため。
COMMENT ON TABLE house_rooms IS '年齢ごとのおへや。layout は配置 JSON (schemaVersion 5)。壁の家具の position の y は底面の高さ (壁は 4.2 m)';
