"""Photo intake: resolve Discord/browser `.url` shortcuts, list photos, contact sheet."""
from __future__ import annotations
from pathlib import Path
import httpx
import numpy as np
from PIL import Image, ImageDraw, ImageOps

PHOTO_EXT = {'.jpg', '.jpeg', '.png', '.webp'}


def resolve_folder(folder: Path) -> list[Path]:
    """Return photo paths in `folder`. `.url` shortcuts are downloaded once into `folder/jpg/`."""
    folder = Path(folder)
    photos = sorted(p for p in folder.iterdir() if p.suffix.lower() in PHOTO_EXT)
    shortcuts = sorted(folder.glob('*.url'))
    if shortcuts:
        dest = folder / 'jpg'
        dest.mkdir(exist_ok=True)
        with httpx.Client(timeout=60, follow_redirects=True) as client:
            for s in shortcuts:
                target = dest / s.name[:-4]
                if not target.exists():
                    url = next((line[4:].strip() for line in s.read_text(encoding='utf-8', errors='replace').splitlines()
                                if line.startswith('URL=')), None)
                    if not url:
                        continue
                    r = client.get(url)
                    r.raise_for_status()
                    target.write_bytes(r.content)
                photos.append(target)
        if (dest).exists():
            photos += [p for p in dest.iterdir() if p.suffix.lower() in PHOTO_EXT and p not in photos]
    seen, out = set(), []
    for p in sorted(photos, key=lambda p: p.name):
        if p.name not in seen:
            seen.add(p.name); out.append(p)
    return out


def contact_sheet(paths: list[Path], out: Path, cell=360) -> Path:
    """All photos on one image with their file names (one look instead of N)."""
    n = len(paths)
    cols = min(4, max(1, n))
    rows = (n + cols - 1) // cols
    h = int(cell * 4 / 3)
    sheet = Image.new('RGB', (cols * cell, rows * (h + 28)), 'white')
    draw = ImageDraw.Draw(sheet)
    from .fonts import ui_font
    font = ui_font(18)
    for i, p in enumerate(paths):
        im = ImageOps.exif_transpose(Image.open(p)).convert('RGB')
        im.thumbnail((cell, h))
        x, y = (i % cols) * cell, (i // cols) * (h + 28)
        sheet.paste(im, (x + (cell - im.width) // 2, y))
        draw.text((x + 4, y + h + 2), f'{i + 1}: {p.name}', fill='black', font=font)
    out.parent.mkdir(parents=True, exist_ok=True)
    sheet.save(out, quality=85)
    return out


def load_bgr(path: Path) -> np.ndarray:
    import cv2
    img = cv2.imdecode(np.fromfile(str(path), np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise ValueError(f'cannot read image: {path}')
    return img
