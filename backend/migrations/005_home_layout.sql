-- おうちの配置 JSON (1 行のみ)。家具と作品をどこに置くかの、ただ 1 つの正。
-- 初期値は SQL に入れず、サーバーの起動時に static/home/default-layout.json から入れる。
CREATE TABLE IF NOT EXISTS home_layout (
    id SMALLINT PRIMARY KEY CHECK (id = 1),
    layout JSONB NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Supabase から外に公開されないようにする (004 と同じ理由)
ALTER TABLE home_layout ENABLE ROW LEVEL SECURITY;
