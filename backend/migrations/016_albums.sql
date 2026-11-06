-- アルバム: 作品を自分で好きなグループにまとめる (作品一覧の上の棚)。
-- 1 つの作品をいくつのアルバムにも入れられる。作品やアルバムを消すと、入れた記録も消える。
-- お気に入り (artworks.favorite) は、表を持たない最初からあるアルバムとして albums.rs が並べる。
CREATE TABLE IF NOT EXISTS albums (
    id UUID PRIMARY KEY,
    name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS album_artworks (
    album_id UUID NOT NULL REFERENCES albums (id) ON DELETE CASCADE,
    artwork_id UUID NOT NULL REFERENCES artworks (id) ON DELETE CASCADE,
    added_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (album_id, artwork_id)
);

-- 作品の詳細で「入っているアルバム」を調べる
CREATE INDEX IF NOT EXISTS album_artworks_artwork_idx
    ON album_artworks (artwork_id);
