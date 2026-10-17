-- おうちを中央のリビング (10 × 10 m) だけにする。左・右・前の部屋と、リビングの出入口を無くす。配置 JSON は schemaVersion 5 になる。
-- 配置を v5 に上げるのは SQL ではなく、サーバーの起動時の処理 (home_api.rs の ensure_layout)。
-- 左・右・前の部屋にあった家具と作品は配置から外し、外した作品は reconcile が空いている所へ置き直す (home.rs の drop_legacy_rooms)。
--
-- 古いビルドが VersionMissing(9) で止まるための番兵 (007・008 と同じ)。
-- 古いサーバーは v5 の配置 (rooms が hub だけ) を読めないと初期配置に戻して保存してしまうので、
-- このマイグレーションが入ったデータベースでは起動できないようにしておく。
COMMENT ON COLUMN home_layout.schema_version IS '配置 JSON の schemaVersion。5 = 中央のリビング (10 × 10) だけの家';
