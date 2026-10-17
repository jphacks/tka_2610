CREATE TABLE IF NOT EXISTS exhibits (
    id UUID PRIMARY KEY,

    title TEXT NOT NULL,

    model_url TEXT NOT NULL,

    slot_id TEXT NOT NULL,

    status TEXT NOT NULL DEFAULT 'ready',

    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO exhibits (
    id,
    title,
    model_url,
    slot_id,
    status
)
VALUES (
    '11111111-1111-1111-1111-111111111111',
    'sample exhibit',
    'http://localhost:8080/models/sample.glb',
    'SLOT_004',
    'ready'
)
ON CONFLICT (id) DO NOTHING;