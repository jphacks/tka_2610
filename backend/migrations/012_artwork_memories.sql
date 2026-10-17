-- 作品の「おもいで」。作品ごとに、写真・動画・声の記録をいくつでも付けられる (memories.rs)。
-- ファイルは media/memories/ に置き、file はそのファイル名。写真は小さい画像 thumb_file も作る。動画と声は送られたまま置く (変換しない)。
-- duration_ms・width・height は Web が測って送る値 (動画と声の長さ、写真と動画の大きさ)。
--
-- 古いサーバーはこの表を読まないだけで動くので、番兵にはしない。古いサーバーで作品を消すと行は CASCADE で消えてファイルだけ残るが、
-- 新しいサーバーの起動時に、表に無いファイルを消す (memories.rs の remove_orphans)。
CREATE TABLE IF NOT EXISTS artwork_memories (
    id UUID PRIMARY KEY,
    artwork_id UUID NOT NULL REFERENCES artworks (id) ON DELETE CASCADE,
    kind TEXT NOT NULL CHECK (kind IN ('photo', 'video', 'audio')),
    file TEXT NOT NULL,
    thumb_file TEXT,
    mime TEXT NOT NULL,
    bytes BIGINT NOT NULL,
    duration_ms INTEGER,
    width INTEGER,
    height INTEGER,
    caption TEXT NOT NULL DEFAULT '',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Supabase から外に公開されないようにする (004 と同じ理由)
ALTER TABLE artwork_memories ENABLE ROW LEVEL SECURITY;

CREATE INDEX IF NOT EXISTS artwork_memories_artwork_idx ON artwork_memories (artwork_id, created_at);
