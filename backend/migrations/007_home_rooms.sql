-- おうちを 4 部屋 (中央のリビング・左・右・前) に広げる。配置 JSON は schemaVersion 3 になる。
-- 保存している配置 JSON の版を列に持たせる。サーバーは配置を書くときに 3 を入れる
-- (既存の行は 2 のまま。次の起動で配置を v3 に上げて 3 にする)。
--
-- 古いビルドが VersionMissing(7) で止まるための番兵でもある。
-- 古いサーバーは v3 の配置を読めないと初期配置に戻して保存してしまうので、
-- このマイグレーションが入ったデータベースでは起動できないようにしておく。
ALTER TABLE home_layout ADD COLUMN IF NOT EXISTS schema_version SMALLINT NOT NULL DEFAULT 2;
