-- 作品の目録番号 (博物館の収蔵番号のように 1 から順に振る)
ALTER TABLE artworks ADD COLUMN IF NOT EXISTS catalog_no BIGSERIAL;
