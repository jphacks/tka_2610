-- おうちの部屋を広げる (中央のリビング 8 × 8 → 10 × 10 m、左・右・前 6 × 6 → 8 × 8 m)。配置 JSON は schemaVersion 4 になる。
-- 配置を v4 に上げるのは SQL ではなく、サーバーの起動時の処理 (home_api.rs の ensure_layout)。
-- 壁ぎわの家具と床の作品は、部屋が広がった分だけ壁といっしょに動かす (home.rs の widen_from_v3)。
--
-- 古いビルドが VersionMissing(8) で止まるための番兵 (007 と同じ)。
-- 古いサーバーは v4 の配置 (部屋の大きさ 10・8) を読めないと初期配置に戻して保存してしまうので、
-- このマイグレーションが入ったデータベースでは起動できないようにしておく。
COMMENT ON COLUMN home_layout.schema_version IS '配置 JSON の schemaVersion。4 = 10 × 10 と 8 × 8 の 4 部屋';
