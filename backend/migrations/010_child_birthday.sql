-- 子どもの誕生日。作品の作成日 (made_on) から「作ったときの年齢」を計算し、年齢ごとのおへやに分けるのに使う。
-- 今ある行 (デモの「はると」) には、サンプルの作品 13 点が 3〜5 さいに分かれる誕生日を入れる。設定の画面で変えられる。
ALTER TABLE museum_settings ADD COLUMN IF NOT EXISTS child_birthday DATE;
UPDATE museum_settings SET child_birthday = DATE '2021-06-01' WHERE id = 1 AND child_birthday IS NULL;
