//! Durable Object の SQLite を読み書きする (backend の sqlx の代わり)。
//!
//! Durable Object の SQL は同期で動き、1 つのおへやの書き込みの途中にほかの要求が割り込むことはない
//! (backend の家全体のロック lock_house の代わり)。まとめて書くときは `tx` で 1 つのトランザクションにする
//! (途中で Err を返すと、それまでの書き込みは取り消される)。
//!
//! 値の形 (backend の PostgreSQL の型との対応):
//! - UUID は文字列 (例 "7505d491-…")、日付は "2026-11-08"、日時は "2026-11-08T07:00:00.000Z" (UTC の文字列なので並べ替えられる)
//! - bool は 0 / 1 (読むときは `flag` で bool にする)
//! - 配置 JSON は文字列
//! - UUID の配列は JSON の配列の文字列にして `json_each(?)` で使う

use std::{cell::RefCell, rc::Rc};

use chrono::{DateTime, NaiveDate, SecondsFormat, Utc};
use serde::{de::DeserializeOwned, Deserialize, Deserializer};
use uuid::Uuid;
use worker::{
    js_sys::{Function, Reflect},
    wasm_bindgen::{closure::Closure, JsCast, JsValue},
    SqlStorage, SqlStorageValue,
};

use crate::error::{AppError, AppResult};

/// SQL に渡す値
pub struct Val(SqlStorageValue);

pub trait ToVal {
    fn to_val(&self) -> Val;
}

impl ToVal for Val {
    fn to_val(&self) -> Val {
        Val(self.0.clone())
    }
}

impl ToVal for str {
    fn to_val(&self) -> Val {
        Val(SqlStorageValue::from(self))
    }
}

impl ToVal for String {
    fn to_val(&self) -> Val {
        self.as_str().to_val()
    }
}

impl ToVal for bool {
    fn to_val(&self) -> Val {
        Val(SqlStorageValue::from(i64::from(*self)))
    }
}

macro_rules! int_val {
    ($($t:ty),*) => {$(
        impl ToVal for $t {
            fn to_val(&self) -> Val {
                Val(SqlStorageValue::from(i64::from(*self)))
            }
        }
    )*};
}
int_val!(i16, i32, i64, u32);

impl ToVal for usize {
    fn to_val(&self) -> Val {
        Val(SqlStorageValue::from(*self as i64))
    }
}

impl ToVal for f64 {
    fn to_val(&self) -> Val {
        Val(SqlStorageValue::from(*self))
    }
}

impl ToVal for Uuid {
    fn to_val(&self) -> Val {
        self.to_string().to_val()
    }
}

impl ToVal for NaiveDate {
    fn to_val(&self) -> Val {
        self.format("%Y-%m-%d").to_string().to_val()
    }
}

impl ToVal for DateTime<Utc> {
    fn to_val(&self) -> Val {
        timestamp(*self).to_val()
    }
}

impl ToVal for [u8] {
    fn to_val(&self) -> Val {
        Val(SqlStorageValue::from(self.to_vec()))
    }
}

impl ToVal for Vec<u8> {
    fn to_val(&self) -> Val {
        self.as_slice().to_val()
    }
}

impl ToVal for serde_json::Value {
    fn to_val(&self) -> Val {
        self.to_string().to_val()
    }
}

impl<T: ToVal + ?Sized> ToVal for &T {
    fn to_val(&self) -> Val {
        (**self).to_val()
    }
}

impl<T: ToVal> ToVal for Option<T> {
    fn to_val(&self) -> Val {
        match self {
            Some(v) => v.to_val(),
            None => Val(SqlStorageValue::Null),
        }
    }
}

/// UUID の配列 (`json_each(?)` で使う)
pub fn uuid_list(ids: &[Uuid]) -> Val {
    serde_json::to_string(ids).expect("uuid list").to_val()
}

/// 配置 JSON などを JSON の文字列にする
pub fn json<T: serde::Serialize>(value: &T) -> AppResult<Val> {
    Ok(serde_json::to_string(value).map_err(AppError::internal)?.to_val())
}

/// `params![a, b]` → Vec<Val>
#[macro_export]
macro_rules! params {
    () => { Vec::<$crate::db::Val>::new() };
    ($($v:expr),+ $(,)?) => { vec![$($crate::db::ToVal::to_val(&$v)),+] };
}

/// 日時を DB に書く形 (UTC。ミリ秒まで)
pub fn timestamp(at: DateTime<Utc>) -> String {
    at.to_rfc3339_opts(SecondsFormat::Millis, true)
}

/// 0 / 1 の列を bool で読む
pub fn flag<'de, D: Deserializer<'de>>(d: D) -> Result<bool, D::Error> {
    Ok(i64::deserialize(d)? != 0)
}

#[derive(Clone)]
pub struct Db {
    sql: SqlStorage,
    /// ctx.storage (transactionSync を呼ぶ)
    storage: JsValue,
}

// Workers は 1 本のスレッドで動く (worker の SqlStorage と同じ扱い)
unsafe impl Send for Db {}
unsafe impl Sync for Db {}

fn sql_error(sql: &str, error: impl std::fmt::Display) -> AppError {
    AppError::internal(format!("{error} ({})", sql.split_whitespace().collect::<Vec<_>>().join(" ")))
}

impl Db {
    pub fn new(sql: SqlStorage, storage: JsValue) -> Self {
        Db { sql, storage }
    }

    fn run(&self, sql: &str, params: Vec<Val>) -> AppResult<worker::SqlCursor> {
        let bindings: Vec<SqlStorageValue> = params.into_iter().map(|v| v.0).collect();
        self.sql.exec(sql, bindings).map_err(|e| sql_error(sql, e))
    }

    /// 行を構造体で読む (列の名前で合わせる)
    pub fn all<T: DeserializeOwned>(&self, sql: &str, params: Vec<Val>) -> AppResult<Vec<T>> {
        self.run(sql, params)?.to_array().map_err(|e| sql_error(sql, e))
    }

    /// 1 行目 (無ければ None)
    pub fn opt<T: DeserializeOwned>(&self, sql: &str, params: Vec<Val>) -> AppResult<Option<T>> {
        Ok(self.all(sql, params)?.into_iter().next())
    }

    /// 1 行目 (無ければ 404。backend の sqlx の RowNotFound と同じ)
    pub fn one<T: DeserializeOwned>(&self, sql: &str, params: Vec<Val>) -> AppResult<T> {
        self.opt(sql, params)?.ok_or_else(|| AppError::not_found("作品が見つかりません"))
    }

    /// 行を組 (タプル) で読む (列の順で合わせる)
    pub fn tuples<T: DeserializeOwned>(&self, sql: &str, params: Vec<Val>) -> AppResult<Vec<T>> {
        let cursor = self.run(sql, params)?;
        cursor
            .raw()
            .map(|row| {
                let row = row.map_err(|e| sql_error(sql, e))?;
                let array: JsValue = row.into_iter().map(JsValue::from).collect::<worker::js_sys::Array>().into();
                serde_wasm_bindgen::from_value(array).map_err(|e| sql_error(sql, e))
            })
            .collect()
    }

    /// 1 列目の値 (無ければ None)
    pub fn scalar<T: DeserializeOwned>(&self, sql: &str, params: Vec<Val>) -> AppResult<Option<T>> {
        Ok(self.tuples::<(T,)>(sql, params)?.into_iter().next().map(|(v,)| v))
    }

    /// 書き込む。書いた行の数を返す
    pub fn exec(&self, sql: &str, params: Vec<Val>) -> AppResult<usize> {
        let cursor = self.run(sql, params)?;
        // 結果を読み切ってから数える
        for row in cursor.raw() {
            row.map_err(|e| sql_error(sql, e))?;
        }
        Ok(cursor.rows_written())
    }

    /// いくつかの文をまとめて流す (スキーマの作成など。値は渡せない)
    pub fn batch(&self, sql: &str) -> AppResult<()> {
        self.exec(sql, params![]).map(|_| ())
    }

    /// 1 つのトランザクションで書く (ctx.storage.transactionSync)。f が Err を返したら、f の中の書き込みは取り消す
    pub fn tx<R: 'static>(&self, f: impl FnOnce() -> AppResult<R>) -> AppResult<R> {
        let slot: Rc<RefCell<Option<AppResult<R>>>> = Rc::new(RefCell::new(None));
        let inner = slot.clone();
        // f は transactionSync の中ですぐに呼ばれるので、'static にするために一度 Box にする
        let f: Box<dyn FnOnce() -> AppResult<R>> = unsafe { std::mem::transmute::<Box<dyn FnOnce() -> AppResult<R> + '_>, Box<dyn FnOnce() -> AppResult<R>>>(Box::new(f)) };
        let callback = Closure::once_into_js(move || -> Result<JsValue, JsValue> {
            let result = f();
            let failed = result.is_err();
            *inner.borrow_mut() = Some(result);
            // 例外にすると transactionSync が取り消す
            if failed { Err(JsValue::from_str("rollback")) } else { Ok(JsValue::UNDEFINED) }
        });
        let transaction_sync: Function = Reflect::get(&self.storage, &JsValue::from_str("transactionSync"))
            .map_err(|e| AppError::internal(format!("transactionSync: {e:?}")))?
            .dyn_into()
            .map_err(|e| AppError::internal(format!("transactionSync: {e:?}")))?;
        let called = transaction_sync.call1(&self.storage, &callback);
        let result = slot.borrow_mut().take();
        match (result, called) {
            (Some(result), _) => result,
            (None, Err(e)) => Err(AppError::internal(format!("transaction: {e:?}"))),
            (None, Ok(_)) => Err(AppError::internal("transaction: no result")),
        }
    }
}

/// SQL の中の「今の日時」(DB に書く形。backend の NOW())
#[macro_export]
macro_rules! now_sql {
    () => {
        "strftime('%Y-%m-%dT%H:%M:%fZ', 'now')"
    };
}
