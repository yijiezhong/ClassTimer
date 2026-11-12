#!/usr/bin/env python3
"""生成课堂计时器 App 图标（参照 Markable 的版式）。

构成：
  黑色斜向渐变圆角底
  左侧一道细竖线（半透明白，圆角）
  白色衬线大写 C（Didot，优雅）

产出：
  assets/AppIcon.png        1024×1024 主图
  assets/AppIcon.iconset/   各尺寸
  assets/AppIcon.icns       最终图标
"""

from __future__ import annotations

import os
import subprocess

import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "assets")

SIZE = 1024
RADIUS = 230

# Didot 的衬线对比强烈，配合细线更接近 Markable 的精致感
# 必须用正体：Bodoni 72.ttc 的 index 1 是 Book Italic（斜体）。
# 选 Baskerville Bold（index 1，正体）：衬线精致、笔画足够粗，
# 比 Bodoni 更耐缩放，兼顾优雅与小尺寸清晰度。
FONT_PATH = "/System/Library/Fonts/Supplemental/Baskerville.ttc"
FONT_INDEX = 1          # Bold（正体）
FONT_SIZE = 640

# 16/32px 下衬线细节会糊，单独用更粗、更大的 C（无细线）渲染小尺寸版
SMALL_FONT_PATH = "/System/Library/Fonts/Supplemental/Georgia Bold.ttf"
SMALL_FONT_SIZE = 760

# 左侧细线：位置和宽度按 1024 画布定
LINE_X = 158
LINE_TOP = 268
LINE_BOTTOM = 756
LINE_WIDTH = 26
LINE_ALPHA = 78         # 约 30% 白

LETTER_SHIFT_X = 34     # C 视觉居中偏右，给左侧细线留呼吸


def build_background() -> Image.Image:
    """黑色斜向渐变 + 顶部微光，裁成圆角。"""
    yy, xx = np.mgrid[0:SIZE, 0:SIZE].astype(np.float32)
    t = (xx + yy) / (2.0 * SIZE)
    base = 44.0 - 38.0 * t                      # 左上 44 -> 右下 6
    arr = np.stack([base, base, base * 1.03], axis=-1)

    glow = np.clip(1.0 - yy / (SIZE * 0.55), 0.0, 1.0) ** 2 * 14.0
    arr = arr + glow[..., None]

    rgb = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), "RGB").convert("RGBA")
    mask = Image.new("L", (SIZE, SIZE), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SIZE, SIZE], radius=RADIUS, fill=255)
    rgb.putalpha(mask)
    return rgb


def draw_side_line(img: Image.Image) -> Image.Image:
    canvas = img.copy()
    draw = ImageDraw.Draw(canvas)
    draw.rounded_rectangle(
        [LINE_X, LINE_TOP, LINE_X + LINE_WIDTH, LINE_BOTTOM],
        radius=LINE_WIDTH // 2,
        fill=(255, 255, 255, LINE_ALPHA),
    )
    return canvas


def draw_letter(img: Image.Image, letter: str = "C",
                font_path: str = FONT_PATH, font_size: int = FONT_SIZE,
                shift_x: int = LETTER_SHIFT_X) -> Image.Image:
    font = ImageFont.truetype(font_path, font_size, index=FONT_INDEX if font_path == FONT_PATH else 0)
    canvas = img.copy()
    draw = ImageDraw.Draw(canvas)
    bbox = draw.textbbox((0, 0), letter, font=font)
    w = bbox[2] - bbox[0]
    h = bbox[3] - bbox[1]
    x = (SIZE - w) / 2 - bbox[0] + shift_x
    y = (SIZE - h) / 2 - bbox[1]
    draw.text((x, y), letter, font=font, fill=(255, 255, 255, 255))
    return canvas


def make_iconset(master: Image.Image, small_master: Image.Image) -> str:
    iconset = os.path.join(ASSETS, "AppIcon.iconset")
    os.makedirs(iconset, exist_ok=True)
    for pair, px in [
        ("16x16", 16), ("16x16@2x", 32),
        ("32x32", 32), ("32x32@2x", 64),
        ("128x128", 128), ("128x128@2x", 256),
        ("256x256", 256), ("256x256@2x", 512),
        ("512x512", 512), ("512x512@2x", 1024),
    ]:
        # 32px 及以下用「粗版 C、无细线」的简化图，避免衬线在小尺寸糊成一团
        src = small_master if px <= 32 else master
        src.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, f"icon_{pair}.png"))
    return iconset


def main() -> None:
    os.makedirs(ASSETS, exist_ok=True)

    master = build_background()
    master = draw_side_line(master)
    master = draw_letter(master, "C")

    # 小尺寸专用：更粗、更大的 C，不加细线
    small_master = draw_letter(
        build_background(), "C",
        font_path=SMALL_FONT_PATH, font_size=SMALL_FONT_SIZE, shift_x=0
    )

    png_path = os.path.join(ASSETS, "AppIcon.png")
    master.save(png_path)
    print(f"主图：{png_path}")

    iconset = make_iconset(master, small_master)
    icns_path = os.path.join(ASSETS, "AppIcon.icns")
    subprocess.run(["iconutil", "-c", "icns", "-o", icns_path, iconset], check=True)
    print(f"图标：{icns_path}  ({os.path.getsize(icns_path)} 字节)")


if __name__ == "__main__":
    main()
