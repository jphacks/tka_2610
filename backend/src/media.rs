//! アップロード写真の処理 (すべて CPU 処理なので spawn_blocking から呼ぶ)
//!
//! 1 回のデコードから以下を並列に作る:
//! - 表示用画像 (長辺 1600px JPEG)
//! - 一覧用サムネイル (400x400 正方形 JPEG)
//! - 3D モデル用テクスチャ (長辺 1024px JPEG)
//! - 読み込み中に表示する背景色 (tint)

use std::io::Cursor;

use image::{
    codecs::jpeg::JpegEncoder, imageops::FilterType, DynamicImage, GenericImageView, ImageDecoder,
    ImageReader, RgbImage,
};

pub struct ProcessedImage {
    pub display_jpeg: Vec<u8>,
    pub display_width: u32,
    pub display_height: u32,
    pub thumb_jpeg: Vec<u8>,
    pub texture_jpeg: Vec<u8>,
    pub tint: String,
}

const DISPLAY_MAX: u32 = 1600;
const TEXTURE_MAX: u32 = 1024;
const THUMB_SIZE: u32 = 400;

pub fn decode(bytes: &[u8]) -> Result<RgbImage, String> {
    let reader = ImageReader::new(Cursor::new(bytes))
        .with_guessed_format()
        .map_err(|e| format!("画像を読み込めません: {e}"))?;

    if reader.format().is_none() {
        return Err("対応していない画像形式です (JPEG / PNG / WebP を選んでください)".into());
    }

    let mut decoder = reader
        .into_decoder()
        .map_err(|e| format!("画像を読み込めません: {e}"))?;

    // スマホ写真の EXIF 回転を反映する
    let orientation = decoder.orientation().ok();

    let mut image =
        DynamicImage::from_decoder(decoder).map_err(|e| format!("画像を読み込めません: {e}"))?;

    if let Some(orientation) = orientation {
        image.apply_orientation(orientation);
    }

    Ok(flatten_on_white(image))
}

/// 透過 PNG は白い紙の上に置いた見た目にする
fn flatten_on_white(image: DynamicImage) -> RgbImage {
    if !image.color().has_alpha() {
        return image.to_rgb8();
    }

    let rgba = image.to_rgba8();
    let (w, h) = rgba.dimensions();
    let mut out = RgbImage::new(w, h);
    for (x, y, p) in rgba.enumerate_pixels() {
        let a = p[3] as u32;
        let blend = |c: u8| ((c as u32 * a + 255 * (255 - a)) / 255) as u8;
        out.put_pixel(x, y, image::Rgb([blend(p[0]), blend(p[1]), blend(p[2])]));
    }
    out
}

fn fit_within(image: &DynamicImage, max: u32) -> DynamicImage {
    let (w, h) = image.dimensions();
    if w <= max && h <= max {
        return image.clone();
    }
    image.resize(max, max, FilterType::Triangle)
}

pub fn encode_jpeg(image: &DynamicImage, quality: u8) -> Vec<u8> {
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, quality)
        .encode_image(&image.to_rgb8())
        .expect("JPEG encoding into memory cannot fail");
    out
}

/// サムネイルの平均色をクリーム色に寄せたパステル色
fn tint_of(thumb: &DynamicImage) -> String {
    let rgb = thumb.to_rgb8();
    let n = (rgb.width() * rgb.height()).max(1) as u64;
    let mut sum = [0u64; 3];
    for p in rgb.pixels() {
        for k in 0..3 {
            sum[k] += p[k] as u64;
        }
    }
    let cream = [0xfb, 0xf4, 0xec];
    let mix = |k: usize| ((sum[k] / n) as u32 * 45 / 100 + cream[k] as u32 * 55 / 100) as u8;
    format!("#{:02x}{:02x}{:02x}", mix(0), mix(1), mix(2))
}

pub fn process(bytes: &[u8]) -> Result<ProcessedImage, String> {
    let original = DynamicImage::ImageRgb8(decode(bytes)?);

    let (w, h) = original.dimensions();
    if w < 16 || h < 16 {
        return Err("画像が小さすぎます".into());
    }

    // 以降の縮小はすべて表示用画像から行う (元画像は大きいので 1 回だけ縮小)
    let display = fit_within(&original, DISPLAY_MAX);
    drop(original);

    let (display_jpeg, (thumb_jpeg, tint), texture_jpeg) = std::thread::scope(|scope| {
        let thumb = scope.spawn(|| {
            let thumb = display.resize_to_fill(THUMB_SIZE, THUMB_SIZE, FilterType::Triangle);
            (encode_jpeg(&thumb, 80), tint_of(&thumb))
        });
        let texture = scope.spawn(|| encode_jpeg(&fit_within(&display, TEXTURE_MAX), 85));
        let display_jpeg = encode_jpeg(&display, 86);
        (
            display_jpeg,
            thumb.join().expect("thumbnail thread"),
            texture.join().expect("texture thread"),
        )
    });

    Ok(ProcessedImage {
        display_width: display.width(),
        display_height: display.height(),
        display_jpeg,
        thumb_jpeg,
        texture_jpeg,
        tint,
    })
}

/// おもいでの写真 (作品の写真と同じ大きさの表示用画像と正方形の小さい画像。テクスチャと背景色は作らない)
pub struct ProcessedPhoto {
    pub display_jpeg: Vec<u8>,
    pub width: u32,
    pub height: u32,
    pub thumb_jpeg: Vec<u8>,
}

pub fn process_photo(bytes: &[u8]) -> Result<ProcessedPhoto, String> {
    let original = DynamicImage::ImageRgb8(decode(bytes)?);
    let (w, h) = original.dimensions();
    if w < 16 || h < 16 {
        return Err("画像が小さすぎます".into());
    }
    let display = fit_within(&original, DISPLAY_MAX);
    drop(original);
    let thumb = display.resize_to_fill(THUMB_SIZE, THUMB_SIZE, FilterType::Triangle);
    Ok(ProcessedPhoto {
        width: display.width(),
        height: display.height(),
        display_jpeg: encode_jpeg(&display, 86),
        thumb_jpeg: encode_jpeg(&thumb, 80),
    })
}

/// 保存済みの表示用 JPEG からテクスチャだけ作り直す (カテゴリ変更時)
pub fn texture_from_display(bytes: &[u8]) -> Result<(Vec<u8>, u32, u32), String> {
    let image = DynamicImage::ImageRgb8(decode(bytes)?);
    let (w, h) = image.dimensions();
    Ok((encode_jpeg(&fit_within(&image, TEXTURE_MAX), 85), w, h))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_png(w: u32, h: u32) -> Vec<u8> {
        let img = RgbImage::from_fn(w, h, |x, _| image::Rgb([(x % 255) as u8, 120, 200]));
        let mut out = Vec::new();
        DynamicImage::ImageRgb8(img)
            .write_to(&mut Cursor::new(&mut out), image::ImageFormat::Png)
            .unwrap();
        out
    }

    #[test]
    fn processes_large_image() {
        let result = process(&sample_png(2400, 1200)).unwrap();
        assert_eq!((result.display_width, result.display_height), (1600, 800));
        let thumb = image::load_from_memory(&result.thumb_jpeg).unwrap();
        assert_eq!(thumb.dimensions(), (400, 400));
        let texture = image::load_from_memory(&result.texture_jpeg).unwrap();
        assert_eq!(texture.dimensions(), (1024, 512));
        assert!(result.tint.starts_with('#') && result.tint.len() == 7);
    }

    #[test]
    fn rejects_non_images() {
        assert!(process(b"not an image at all").is_err());
    }
}
