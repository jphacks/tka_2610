-- 壁に掛ける家具 (壁のキャビネット・壁の飾り棚・ピクチャーレッジ。static/home/catalog.json の placement が "wall") を足した版。
-- 表の形は変えない。配置 JSON (house_rooms.layout) の家具の position の y に、壁の家具の底面の高さが入る。
--
-- 古いビルドが VersionMissing(13) で止まるための番兵 (011 と同じ考え方)。古いサーバーは壁の家具を知らないので、
-- 壁の家具のあるおへやを読むと配置を直せず (repair_layout は作品しか外せない)、初期配置に戻して保存してしまうため。
COMMENT ON TABLE house_rooms IS '年齢ごとのおへや。layout は配置 JSON (schemaVersion 5)。壁の家具の position の y は底面の高さ';
