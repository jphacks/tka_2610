//! 体験用の家を、開いた人ごとに分ける (テストでいろいろな人に触ってもらうため)。
//!
//! - 家の番号 (ランダムな 32 桁の 16 進数) を Cookie `memoria_house` に入れる。番号ごとに Durable Object が 1 つ
//! - Cookie が無い人には、画面を開いたときに新しい番号を付ける (新しい家はサンプルの作品 33 点から始まる)
//! - `?house=<番号>` で開くとその家に切り替わる (ほかの端末へ引き継ぐ・人に見せる)。`?house=new` で新しい家
//! - `/house` は「この家のリンク」と「最初からやり直す」の画面
//!
//! 番号を知っている人は、その家を見ることも書き換えることもできる (ログインの代わりにはならない)。

use worker::{Headers, Request, Response, Result, Url};

pub const COOKIE: &str = "memoria_house";
const ONE_YEAR: u32 = 60 * 60 * 24 * 365;

/// どの家か。`fresh` は、この要求で新しく番号を付けた (応答で Cookie を渡す)
pub struct House {
    pub id: String,
    pub fresh: bool,
}

fn valid(id: &str) -> bool {
    id.len() == 32 && id.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn new_id() -> String {
    uuid::Uuid::new_v4().simple().to_string()
}

/// Cookie の家。無ければ新しい家
pub fn of_request(req: &Request) -> House {
    let cookie = req.headers().get("Cookie").ok().flatten().unwrap_or_default();
    let found = cookie
        .split(';')
        .filter_map(|part| part.trim().strip_prefix(COOKIE).and_then(|rest| rest.strip_prefix('=')))
        .find(|id| valid(id));
    match found {
        Some(id) => House { id: id.to_owned(), fresh: false },
        None => House { id: new_id(), fresh: true },
    }
}

/// Durable Object の名前 (前の、みんなで 1 つの家は "main")
pub fn object_name(house: &House) -> String {
    format!("house-{}", house.id)
}

fn cookie_value(id: &str) -> String {
    format!("{COOKIE}={id}; Path=/; Max-Age={ONE_YEAR}; SameSite=Lax; Secure; HttpOnly")
}

/// 応答に Cookie を足す。fetch で受け取った応答のヘッダーは書き換えられないので、写してから足す
pub fn with_cookie(res: Response, id: &str) -> Result<Response> {
    let headers = Headers::new();
    for (name, value) in res.headers().entries() {
        headers.append(&name, &value)?;
    }
    headers.append("Set-Cookie", &cookie_value(id))?;
    // 家ごとに中身が違うので、Cookie の付いた応答を共有のキャッシュに入れない
    headers.set("Cache-Control", "private, no-store")?;
    Ok(res.with_headers(headers))
}

/// `?house=<番号>`・`?house=new` で開いたとき：Cookie を付けて、`house` を外した URL へ移す
pub fn switch(req: &Request) -> Result<Option<Response>> {
    let url = req.url()?;
    let Some(wanted) = url.query_pairs().find(|(k, _)| k == "house").map(|(_, v)| v.into_owned()) else {
        return Ok(None);
    };
    let id = match wanted.as_str() {
        "new" => new_id(),
        id if valid(id) => id.to_owned(),
        _ => return Ok(None),
    };
    let mut next: Url = url.clone();
    let rest: Vec<(String, String)> =
        url.query_pairs().filter(|(k, _)| k != "house").map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
    if rest.is_empty() {
        next.set_query(None);
    } else {
        next.query_pairs_mut().clear().extend_pairs(rest);
    }
    let headers = Headers::new();
    headers.set("Location", &format!("{}{}", next.path(), next.query().map(|q| format!("?{q}")).unwrap_or_default()))?;
    headers.set("Set-Cookie", &cookie_value(&id))?;
    headers.set("Cache-Control", "private, no-store")?;
    Ok(Some(Response::empty()?.with_status(302).with_headers(headers)))
}

/// `/house`：この家のリンクと、最初からやり直すボタン
pub fn page(req: &Request, house: &House) -> Result<Response> {
    let url = req.url()?;
    let origin = url.origin().ascii_serialization();
    let link = format!("{origin}/?house={}", house.id);
    let html = PAGE.replace("{{LINK}}", &link);
    let res = Response::from_html(html)?;
    if house.fresh { with_cookie(res, &house.id) } else { Ok(res) }
}

const PAGE: &str = r#"<!doctype html>
<html lang="ja">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>この家のリンク | memoria</title>
<style>
  :root { color-scheme: light; --bg: #fbf6ee; --card: #fff; --ink: #3d3a36; --sub: #7a736a; --accent: #7a9a6a; --line: #e8dfd2; }
  body { margin: 0; background: var(--bg); color: var(--ink); font-family: system-ui, -apple-system, "Hiragino Sans", sans-serif; line-height: 1.7; }
  main { max-width: 480px; margin: 0 auto; padding: 32px 16px 48px; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { margin: 0 0 16px; color: var(--sub); font-size: 14px; }
  section { background: var(--card); border: 1px solid var(--line); border-radius: 16px; padding: 20px; margin-bottom: 16px; }
  h2 { font-size: 16px; margin: 0 0 8px; }
  input { width: 100%; box-sizing: border-box; font: inherit; font-size: 13px; padding: 10px 12px; border: 1px solid var(--line); border-radius: 10px; background: #faf8f4; color: var(--ink); }
  .row { display: flex; gap: 8px; margin-top: 12px; flex-wrap: wrap; }
  a.button, button { font: inherit; font-size: 14px; border: 0; border-radius: 999px; padding: 10px 18px; cursor: pointer; text-decoration: none; display: inline-block; }
  .primary { background: var(--accent); color: #fff; }
  .plain { background: #efe8dc; color: var(--ink); }
</style>
</head>
<body>
<main>
  <h1>この家のリンク</h1>
  <p>このテスト版では、開いた人ごとに体験用の家があります。この家はこのブラウザに覚えられています。</p>
  <section>
    <h2>ほかの端末で開く・人に見せる</h2>
    <p>このリンクを開くと、同じ家に入れます。リンクを知っている人は、作品の追加や削除もできます。</p>
    <input id="link" value="{{LINK}}" readonly onclick="this.select()">
    <div class="row">
      <button class="primary" type="button" onclick="navigator.clipboard.writeText(document.getElementById('link').value).then(() => { this.textContent = 'コピーしました' })">リンクをコピー</button>
      <a class="button plain" href="/">家にもどる</a>
    </div>
  </section>
  <section>
    <h2>最初からやり直す</h2>
    <p>サンプルの作品だけが入った、新しい家に移ります。今の家に戻るには、上のリンクを開きます。</p>
    <div class="row"><a class="button plain" href="/?house=new">新しい家にする</a></div>
  </section>
</main>
</body>
</html>
"#;
