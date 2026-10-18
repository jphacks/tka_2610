-- 写真の額縁の作品を、部屋の壁に掛けられるようにした版。表の形は変えない。
-- 配置 JSON (house_rooms.layout) の作品に placement: "wall" が入り、その作品の position の y は底面の高さになる。
--
-- 古いビルドが VersionMissing(15) で止まるための番兵 (013・014 と同じ考え方)。古いサーバーは placement を知らないので、
-- 壁に掛けた額縁を壁ぎわの床の作品として読み、壁に近すぎて置けない作品として外して (repair_layout) 保存してしまうため。
COMMENT ON TABLE house_rooms IS '年齢ごとのおへや。layout は配置 JSON (schemaVersion 5)。壁の家具と壁に掛けた作品 (placement "wall") の position の y は底面の高さ (壁は 4.2 m)';
