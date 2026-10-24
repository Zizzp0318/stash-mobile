"""一次性生成 3 个图标候选，横向拼成一张对比图（只为挑方案，不进仓库产物）。

用法：python tools/icon_variants.py  → 输出 Resources/icon-variants.png
"""
from pathlib import Path
from PIL import Image, ImageDraw

# 逻辑坐标一律用 1024 空间（与 draw_icon.py 同一套数值），S=1 即 1:1 绘制
S = 1
SZ = 1024
ROOT = Path(__file__).resolve().parent.parent

BG_TOP, BG_BOT = (22, 23, 27), (8, 8, 10)
CARD_BACK, CARD_MID, CARD_STROKE = (44, 44, 49), (60, 60, 67), (46, 46, 48)
ACCENT = (71, 149, 255)
INK = (13, 13, 14)


def px(v):
    return int(round(v * S))


def base_canvas():
    img = Image.new("RGB", (SZ, SZ), BG_BOT)
    d = ImageDraw.Draw(img)
    for y in range(SZ):
        t = (y / (SZ - 1)) ** 0.85
        d.line([(0, y), (SZ, y)], fill=tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3)))
    return img, d


def card(d, box, fill, stroke=None, r=60):
    x0, y0, x1, y1 = box
    d.rounded_rectangle([px(x0), px(y0), px(x1) - 1, px(y1) - 1], radius=px(r),
                        fill=fill, outline=stroke, width=px(2) if stroke else 0)


def deck(d, front_fill=ACCENT):
    card(d, (192, 202, 832, 672), CARD_BACK, CARD_STROKE)
    card(d, (192, 280, 832, 750), CARD_MID, CARD_STROKE)
    card(d, (192, 358, 832, 828), front_fill)


def glyph_photo(d):
    d.ellipse([px(556), px(500), px(616), px(560)], fill=INK)
    d.polygon([(px(382), px(676)), (px(470), px(556)), (px(540), px(634)),
               (px(584), px(578)), (px(642), px(676))], fill=INK)


def glyph_grid(d):
    s, gap, r = 88, 32, 22
    x0 = 512 - (s * 2 + gap) // 2
    y0 = 593 - (s * 2 + gap) // 2
    for r_ in range(2):
        for c in range(2):
            x = x0 + c * (s + gap)
            y = y0 + r_ * (s + gap)
            d.rounded_rectangle([px(x), px(y), px(x + s) - 1, px(y + s) - 1], radius=px(r), fill=INK)


def variant_a():
    img, d = base_canvas()
    deck(d)
    glyph_photo(d)
    return img


def variant_b():
    img, d = base_canvas()
    deck(d)
    glyph_grid(d)
    return img


def variant_c():
    img, d = base_canvas()
    # 单张卡（无叠层），卡片更小更居中
    card(d, (222, 262, 802, 762), ACCENT)
    glyph_photo(d)
    return img


def main():
    imgs = [variant_a(), variant_b(), variant_c()]
    pad = 24
    sheet = Image.new("RGB", (SZ * 3 + pad * 4, SZ + pad * 2), (5, 5, 6))
    for i, im in enumerate(imgs):
        sheet.paste(im, (pad + i * (SZ + pad), pad))
    sheet = sheet.resize((int(sheet.width * 0.375), int(sheet.height * 0.375)), Image.LANCZOS)
    out = ROOT / "Resources" / "icon-variants.png"
    sheet.save(out, "PNG")
    print("wrote", out, sheet.size)


if __name__ == "__main__":
    main()
