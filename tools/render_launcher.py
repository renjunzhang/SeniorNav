#!/usr/bin/env python3
"""Prepare the user-supplied complete home portrait as Android launcher artwork.

Requires Pillow. Portrait pixels are not regenerated.

No credentials, network access, device data, or Baidu requests are involved.
"""
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw

ROOT = Path(__file__).resolve().parent.parent
ART = ROOT / 'app/artwork'
RES = ROOT / 'app/android/app/src/main/res'
PREVIEWS = ROOT / 'app/build/artwork'
BACKGROUND = '#FDF5EC'
ADAPTIVE_SCALE = 2 / 3  # 72dp nominal viewport in Android's 108dp layer.


def artwork() -> Image.Image:
    art = Image.open(ART / 'home-portrait.png').convert('RGBA')
    r, g, b, _ = art.split()
    brightest = ImageChops.lighter(ImageChops.lighter(r, g), b)
    outside = brightest.point(lambda value: 255 if value < 55 else 0)
    # Only the dark matte connected to image corners is removed; hair/clothing stay intact.
    corners = [
        (0, 0), (art.width - 1, 0),
        (0, art.height - 1), (art.width - 1, art.height - 1),
    ]
    for corner in corners:
        if outside.getpixel(corner) == 255:
            ImageDraw.floodfill(outside, corner, 128)
    art.putalpha(outside.point(lambda value: 0 if value == 128 else 255))
    art = art.crop(art.getbbox())
    size = max(art.size)
    square = Image.new('RGBA', (size, size))
    square.alpha_composite(art, ((size - art.width) // 2, (size - art.height) // 2))
    return square.resize((1024, 1024), Image.Resampling.LANCZOS)


def main() -> None:
    art = artwork()
    icon = art
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    icon.save(PREVIEWS / 'launcher-preview.png')
    for density, legacy_size, adaptive_size in [
        ('mdpi', 48, 108), ('hdpi', 72, 162), ('xhdpi', 96, 216),
        ('xxhdpi', 144, 324), ('xxxhdpi', 192, 432),
    ]:
        legacy = RES / f'mipmap-{density}' / 'ic_launcher.png'
        icon.resize((legacy_size, legacy_size), Image.Resampling.LANCZOS).save(legacy)
        # Faces and roof apex stay inside the safe circle; decorative shoulders may crop.
        foreground = Image.new('RGBA', (adaptive_size, adaptive_size))
        inner = round(adaptive_size * ADAPTIVE_SCALE)
        offset = (adaptive_size - inner) // 2
        foreground.alpha_composite(
            art.resize((inner, inner), Image.Resampling.LANCZOS), (offset, offset),
        )
        path = RES / f'drawable-{density}' / 'ic_launcher_foreground.png'
        path.parent.mkdir(parents=True, exist_ok=True)
        foreground.save(path)

    # Visual review sheet: actual small icon sizes and Android circle/squircle crops.
    sheet = Image.new('RGB', (1000, 610), '#E6ECF3')
    large = icon.resize((480, 480), Image.Resampling.LANCZOS)
    sheet.paste(large, (25, 65), large)
    draw = ImageDraw.Draw(sheet)
    draw.text((30, 28), 'SeniorNav / Together, home', fill='#203E60')
    draw.text((545, 28), 'Android masks + launcher sizes', fill='#203E60')
    for i, shape in enumerate(['circle', 'squircle']):
        layer = Image.new('RGBA', (324, 324), BACKGROUND)
        inner = round(324 * ADAPTIVE_SCALE)
        offset = (324 - inner) // 2
        layer.alpha_composite(
            art.resize((inner, inner), Image.Resampling.LANCZOS), (offset, offset),
        )
        # Typical 72dp adaptive viewport inside the 108dp resource layer.
        layer = layer.crop((54, 54, 270, 270))
        mask = Image.new('L', (216, 216))
        pen = ImageDraw.Draw(mask)
        if shape == 'circle':
            pen.ellipse((0, 0, 215, 215), fill=255)
        else:
            pen.rounded_rectangle((0, 0, 215, 215), radius=48, fill=255)
        sheet.paste(layer.convert('RGB'), (540 + 230 * i, 70), mask)
    for size, x in [(96, 550), (72, 680), (48, 790)]:
        small = icon.resize((size, size), Image.Resampling.LANCZOS)
        sheet.paste(small, (x, 380), small)
        draw.text((x, 490), f'{size}px', fill='#203E60')
    sheet.save(ART / 'launcher-review.png')
    print('Rendered source preview, review sheet, 5 launcher sizes and 5 adaptive foregrounds.')


if __name__ == '__main__':
    main()
