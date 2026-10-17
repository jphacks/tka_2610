-- 作品の実寸 (幅・高さ・奥行き, m)。登録時に GLB から測る。
-- 測れなかった作品 (古い行・GLB が読めないなど) は NULL のままで、配置の判定は面ごとの枠 (art_fit) を使う。
ALTER TABLE artworks
    ADD COLUMN IF NOT EXISTS model_width DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS model_height DOUBLE PRECISION,
    ADD COLUMN IF NOT EXISTS model_depth DOUBLE PRECISION;
