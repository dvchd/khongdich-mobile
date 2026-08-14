#!/usr/bin/env python3
"""Regenerate Không Dịch launcher icons from assets/logo.svg.

Design: white canvas + red badge logo (matching web icon), instead of
the old full-bleed red background.
- Adaptive foreground: full logo (red circle + white marks) inside the
  66dp safe zone, on transparent canvas.
- Legacy icons: white (#FDFDFD) background + badge at ~82% of canvas.
"""
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
LOGO_SVG = ROOT / "assets" / "logo.svg"
RES = ROOT / "android" / "app" / "src" / "main" / "res"

WHITE = (253, 253, 253, 255)

FOREGROUND_SIZES = {
    "mdpi": 108,
    "hdpi": 162,
    "xhdpi": 216,
    "xxhdpi": 324,
    "xxxhdpi": 432,
}
LEGACY_SIZES = {
    "mdpi": 48,
    "hdpi": 72,
    "xhdpi": 96,
    "xxhdpi": 144,
    "xxxhdpi": 192,
}

FOREGROUND_FACTOR = 0.58
LEGACY_FACTOR = 0.82


def render_logo(tmp: Path, width: int = 2048) -> Image.Image:
    out = tmp / "logo.png"
    subprocess.run(
        ["rsvg-convert", "-w", str(width), str(LOGO_SVG), "-o", str(out)],
        check=True,
    )
    img = Image.open(out).convert("RGBA")
    return img


def circle_diameter(img: Image.Image) -> float:
    w, h = img.size
    xs, ys = [], []
    for y in range(0, h, 2):
        for x in range(0, w, 2):
            r, g, b, a = img.getpixel((x, y))
            if r > 150 and g < 80 and a > 128:
                xs.append(x)
                ys.append(y)
    return (max(xs) - min(xs) + max(ys) - min(ys)) / 2


def place_badge(img: Image.Image, canvas: int, factor: float) -> Image.Image:
    src_d = circle_diameter(img)
    scale = (factor * canvas) / src_d
    w = max(1, round(img.width * scale))
    h = max(1, round(img.height * scale))
    badge = img.resize((w, h), Image.LANCZOS)
    off = ((canvas - w) // 2, (canvas - h) // 2)
    return badge, off


def main() -> None:
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        logo = render_logo(tmp)

        for density, size in FOREGROUND_SIZES.items():
            canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
            badge, off = place_badge(logo, size, FOREGROUND_FACTOR)
            canvas.paste(badge, off, badge)
            out = RES / f"mipmap-{density}" / "ic_launcher_foreground.png"
            canvas.save(out)
            print("wrote", out.relative_to(ROOT), size)

        for density, size in LEGACY_SIZES.items():
            canvas = Image.new("RGBA", (size, size), WHITE)
            badge, off = place_badge(logo, size, LEGACY_FACTOR)
            canvas.paste(badge, off, badge)
            for name in ("ic_launcher.png", "ic_launcher_round.png"):
                out = RES / f"mipmap-{density}" / name
                canvas.save(out)
                print("wrote", out.relative_to(ROOT), size)


if __name__ == "__main__":
    main()
