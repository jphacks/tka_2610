-- 年齢ごとのおへや。1 行が 1 つのおへや (積み上げの建物の 1 階分) で、配置 JSON (schemaVersion 5。リビング hub 1 部屋) を 1 つ持つ。
-- age は作品を作ったときの年齢 (子どもの誕生日と作品の作成日から計算する)、floor はその年齢の中での階 (0 が 1 階)。
-- 作品はその年齢のおへやにだけ飾る。artworks.house_room_id は飾っているおへや (飾っていなければ NULL)。
--
-- 今までの配置 (home_layout の 1 行) は残す。サーバーの起動時に、house_rooms が空なら、その家具とテーマを写したおへやを
-- 年齢ごとに作り、飾っていた作品をその年齢のおへやへ置き直す (home_api.rs の ensure_rooms と reconcile)。
--
-- 古いビルドが VersionMissing(11) で止まるための番兵でもある (古いサーバーは house_rooms を知らず、home_layout だけを書き換えてしまう)。
CREATE TABLE IF NOT EXISTS house_rooms (
    id UUID PRIMARY KEY,
    age SMALLINT NOT NULL CHECK (age BETWEEN 0 AND 120),
    floor SMALLINT NOT NULL CHECK (floor >= 0),
    layout JSONB NOT NULL,
    schema_version SMALLINT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (age, floor)
);

-- Supabase から外に公開されないようにする (004 と同じ理由)
ALTER TABLE house_rooms ENABLE ROW LEVEL SECURITY;

ALTER TABLE artworks
    ADD COLUMN IF NOT EXISTS house_room_id UUID REFERENCES house_rooms (id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS artworks_house_room_id_idx ON artworks (house_room_id);
