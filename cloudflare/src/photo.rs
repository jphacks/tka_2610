//! 写真の処理 (backend の media.rs をそのまま使う) の前に、大きな写真を小さく読む。
//!
//! Durable Object のメモリは 128 MB まで。スマホの写真 (4032 × 3024 など) をそのまま読むと、
//! media::process の途中で 140 MB を超える。JPEG は、読むときに 1/2・1/4・1/8 の大きさで読めるので、
//! 表示用の大きさ (長辺 SHRINK_TO) より小さくならない範囲で小さく読み、写真の向き (EXIF) を直してから、
//! 画質の高い JPEG にして media に渡す (media が作る画像の大きさは backend と同じ)。

use std::io::Cursor;

use image::{codecs::jpeg::JpegEncoder, DynamicImage, ImageDecoder, ImageReader, RgbImage};

pub use crate::media::{ProcessedImage, ProcessedPhoto};

/// これより長辺が長い JPEG は小さくしてから media に渡す (media の表示用の画像の長辺 1600px より少し大きく)
const SHRINK_TO: u32 = 2048;

/// 読むときに小さくするときの、長辺のいちばん小さい長さ (media の表示用の画像の長辺と同じ。これより小さくは読まない)
const DISPLAY_MAX: u32 = 1600;

/// 作品の写真 (表示用・サムネイル・テクスチャ・背景色)
pub fn process(bytes: &[u8]) -> Result<ProcessedImage, String> {
    match shrink(bytes) {
        Some(small) => crate::media::process(&small),
        None => crate::media::process(bytes),
    }
}

/// おもいでの写真 (表示用・サムネイル)
pub fn process_photo(bytes: &[u8]) -> Result<ProcessedPhoto, String> {
    match shrink(bytes) {
        Some(small) => crate::media::process_photo(&small),
        None => crate::media::process_photo(bytes),
    }
}

/// 大きな写真なら、小さくして向きを直した JPEG を返す。小さい写真・読めない写真は None (そのまま media に渡す)
fn shrink(bytes: &[u8]) -> Option<Vec<u8>> {
    shrink_jpeg(bytes).or_else(|| shrink_other(bytes))
}

/// JPEG でない大きな写真 (PNG・WebP など)。そのまま読んでから縮める (透過は白い紙の上に置いた見た目にする)
fn shrink_other(bytes: &[u8]) -> Option<Vec<u8>> {
    let (w, h) = ImageReader::new(Cursor::new(bytes)).with_guessed_format().ok()?.into_dimensions().ok()?;
    if w.max(h) <= SHRINK_TO {
        return None;
    }
    let image = DynamicImage::ImageRgb8(crate::media::decode(bytes).ok()?);
    encode(fit(image))
}

/// 長辺を SHRINK_TO に縮める (メモリをあまり使わない縮め方)
fn fit(image: DynamicImage) -> DynamicImage {
    let (w, h) = (image.width(), image.height());
    if w.max(h) <= SHRINK_TO {
        return image;
    }
    let (nw, nh) = if w >= h { (SHRINK_TO, (h * SHRINK_TO / w).max(1)) } else { ((w * SHRINK_TO / h).max(1), SHRINK_TO) };
    image.thumbnail_exact(nw, nh)
}

fn encode(image: DynamicImage) -> Option<Vec<u8>> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 95).encode_image(&image.to_rgb8()).ok()?;
    Some(out)
}

/// 大きな JPEG を、読むときに小さく読む
fn shrink_jpeg(bytes: &[u8]) -> Option<Vec<u8>> {
    let mut decoder = jpeg_decoder::Decoder::new(Cursor::new(bytes));
    decoder.read_info().ok()?;
    let info = decoder.info()?;
    let (w, h) = (u32::from(info.width), u32::from(info.height));
    let long = w.max(h);
    if long <= SHRINK_TO {
        return None;
    }
    // 長辺が DISPLAY_MAX 以上になる、いちばん小さい倍率で読む (1/2・1/4・1/8)
    let want = |side: u32| (side * DISPLAY_MAX / long).max(1) as u16;
    decoder.scale(want(w), want(h)).ok()?;
    let pixels = decoder.decode().ok()?;
    let info = decoder.info()?;
    let (w, h) = (u32::from(info.width), u32::from(info.height));
    let mut image = match info.pixel_format {
        jpeg_decoder::PixelFormat::RGB24 => DynamicImage::ImageRgb8(RgbImage::from_raw(w, h, pixels)?),
        jpeg_decoder::PixelFormat::L8 => DynamicImage::ImageLuma8(image::GrayImage::from_raw(w, h, pixels)?),
        // CMYK などは media にまかせる
        _ => return None,
    };
    // 倍率で小さくしきれなかった分 (例: 3000px → 1/1) は、SHRINK_TO まで縮める
    image = fit(image);

    // 向き (EXIF) は image の読み方で調べる (画素は読まない)
    let orientation = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .ok()
        .and_then(|r| r.into_decoder().ok())
        .and_then(|mut d| d.orientation().ok());
    if let Some(orientation) = orientation {
        image.apply_orientation(orientation);
    }

    encode(image)
}
