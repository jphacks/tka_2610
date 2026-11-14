-- 「すべて」の模様替え。年齢別の house_rooms や作品の展示先は変更しない。
-- state は floors（階ごとの配置）と hidden（利用者が外した作品の id）。
CREATE TABLE all_home_layout (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    state JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
ALTER TABLE all_home_layout ENABLE ROW LEVEL SECURITY;
