"""A font with Japanese glyphs for labels on contact / comparison sheets, on Windows, macOS or Linux.
Falls back to Pillow's built-in font (Latin only) when none of the usual system fonts is there."""
from __future__ import annotations
from functools import lru_cache

from PIL import ImageFont

CANDIDATES = (
    'C:/Windows/Fonts/meiryo.ttc',                                   # Windows
    'C:/Windows/Fonts/YuGothM.ttc',
    '/System/Library/Fonts/ヒラギノ角ゴシック W3.ttc',                  # macOS
    '/System/Library/Fonts/Hiragino Sans GB.ttc',
    '/Library/Fonts/Arial Unicode.ttf',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',        # Linux (Debian / Ubuntu, Fedora)
    '/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc',
)


@lru_cache(maxsize=None)
def ui_font(size: int = 18):
    for path in CANDIDATES:
        try:
            return ImageFont.truetype(path, size)
        except OSError:
            continue
    try:
        return ImageFont.load_default(size)
    except TypeError:                                                # Pillow < 10.1 has no size argument
        return ImageFont.load_default()
