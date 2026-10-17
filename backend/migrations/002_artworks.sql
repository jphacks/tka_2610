-- 子どもの作品 (Web画面の中心データ)
CREATE TABLE IF NOT EXISTS artworks (
    id UUID PRIMARY KEY,

    title TEXT NOT NULL,
    child_name TEXT NOT NULL DEFAULT '',
    age SMALLINT,
    made_on DATE NOT NULL DEFAULT CURRENT_DATE,
    memo TEXT NOT NULL DEFAULT '',
    category TEXT NOT NULL DEFAULT 'drawing'
        CHECK (category IN ('drawing', 'craft', 'photo', 'other')),

    -- Rustが生成したファイル (media ディレクトリからの相対名)
    image_file TEXT NOT NULL,
    thumb_file TEXT NOT NULL,
    model_file TEXT NOT NULL,
    model_kind TEXT NOT NULL
        CHECK (model_kind IN ('frame', 'stand', 'custom')),

    image_width INTEGER NOT NULL,
    image_height INTEGER NOT NULL,
    tint TEXT NOT NULL DEFAULT '#f3e7da',

    favorite BOOLEAN NOT NULL DEFAULT FALSE,

    -- NULL = 未展示。値があるとUnity / Web の博物館に展示される
    slot_id TEXT UNIQUE,
    displayed_at TIMESTAMPTZ,

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS artworks_created_at_idx
    ON artworks (created_at DESC);

CREATE INDEX IF NOT EXISTS artworks_category_made_on_idx
    ON artworks (category, made_on DESC);

-- 博物館の設定 (1行のみ)
CREATE TABLE IF NOT EXISTS museum_settings (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    museum_name TEXT NOT NULL,
    owner_name TEXT NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO museum_settings (id, museum_name, owner_name)
VALUES (1, 'はるのミュージアム', 'はると')
ON CONFLICT (id) DO NOTHING;
