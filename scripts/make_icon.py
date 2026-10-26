"""kgeoScan 앱 아이콘 생성.

1024x1024 원본을 그린 뒤 AppIcon.appiconset/Contents.json 에 적힌 모든 크기로 저장한다.
    python scripts/make_icon.py
필요: Pillow (pip install pillow). 글꼴은 Windows 의 Segoe UI Bold 를 쓰고, 없으면 기본 글꼴.
"""
import json
import os
import sys

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ICONSET = os.path.join(ROOT, "StrayScanner", "Assets.xcassets", "AppIcon.appiconset")
S = 1024

TOP = (12, 40, 92)      # 짙은 남색
BOTTOM = (26, 98, 196)  # 파랑


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def load_font(size):
    for path in (r"C:\Windows\Fonts\segoeuib.ttf", r"C:\Windows\Fonts\arialbd.ttf",
                 "/System/Library/Fonts/Supplemental/Arial Bold.ttf", "/Library/Fonts/Arial Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def draw_base():
    img = Image.new("RGB", (S, S), TOP)
    d = ImageDraw.Draw(img)
    for y in range(S):
        d.line([(0, y), (S, y)], fill=lerp(TOP, BOTTOM, y / (S - 1)))

    # 점구름(LiDAR) 느낌의 점 격자 — 오른쪽 아래
    overlay = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    n = 9
    for i in range(n):
        for j in range(n):
            x = 520 + i * 52
            y = 520 + j * 52
            r = 9 if (i + j) % 3 == 0 else 6
            a = int(70 + 150 * (i + j) / (2 * (n - 1)))
            od.ellipse([x - r, y - r, x + r, y + r], fill=(255, 255, 255, a))
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

    # 큰 'K'
    d = ImageDraw.Draw(img)
    font = load_font(720)
    text = "K"
    bbox = d.textbbox((0, 0), text, font=font)
    w, h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = 96 - bbox[0]
    y = (S - h) // 2 - bbox[1] - 20
    d.text((x + 10, y + 14), text, font=font, fill=(0, 0, 0))          # 그림자
    d.text((x, y), text, font=font, fill=(255, 255, 255))
    return img


def main():
    base = draw_base()
    with open(os.path.join(ICONSET, "Contents.json"), "r", encoding="utf-8") as f:
        spec = json.load(f)
    written = []
    for entry in spec["images"]:
        size = float(entry["size"].split("x")[0])
        scale = int(entry["scale"].rstrip("x"))
        px = int(round(size * scale))
        out = base.resize((px, px), Image.LANCZOS)
        out.save(os.path.join(ICONSET, entry["filename"]), "PNG", optimize=True)
        written.append((entry["filename"], px))
    for name, px in written:
        print(f"{name:12s} {px}px")
    print(f"{len(written)} icons written to {ICONSET}")


if __name__ == "__main__":
    sys.exit(main())
