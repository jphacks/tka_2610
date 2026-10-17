-- Supabase は public スキーマの表を API として公開するので、RLS をオンにして外から読み書きできないようにする。
-- サーバーは表の所有者として接続するので、RLS の対象外で動作は変わらない。
ALTER TABLE artworks ENABLE ROW LEVEL SECURITY;
ALTER TABLE museum_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE exhibits ENABLE ROW LEVEL SECURITY;
ALTER TABLE _sqlx_migrations ENABLE ROW LEVEL SECURITY;
