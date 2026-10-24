"""生成 Stash 的 iOS App 图标（1024×1024）与 AppIcon.appiconset。

设计思路：三张叠在一起的「素材卡片」，最上面一张用强调色 #4795FF 并带一个图片图元。
- 「叠卡片」直接对应 App 的核心隐喻（一堆素材收在库里），比通用的 2×2 宫格更有辨识度；
- 配色严格取桌面端 `main.css` 的 token（#0D0D0E 底 / #1F1F20 / #2E2E30 / #4795FF），
  两个端看起来像同一个产品；
- 先在 4096 画再降采样到 1024，等于拿到 4× 超采样的抗锯齿（Pillow 的
  rounded_rectangle 没有 AA，直接画 1024 边缘会毛）。

用法：python tools/draw_icon.py
"""
from pathlib import Path
from PIL import Image, ImageDraw

S = 4                     # 超采样倍数
W = 1024 * S
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# —— 与桌面端 main.css 对齐的色板 ——
BG_TOP = (22, 23, 27)
BG_BOT = (8, 8, 10)
CARD_BACK = (44, 44, 49)     # 必须和底色拉开：原来用 #17171B，在深底上只剩一圈描边像渲染瑕疵
CARD_MID = (60, 60, 67)
CARD_STROKE = (46, 46, 48)   # --border
ACCENT = (71, 149, 255)      # --accent
INK = (13, 13, 14)           # --bg-app，用作「镂空」色


def px(v: float) -> int:
    return int(round(v * S))


def main() -> None:
    img = Image.new("RGB", (W, W), BG_BOT)
    d = ImageDraw.Draw(img)

    # 纵向渐变：轻微的上亮下暗，让图标在深色主屏上有一点点体积感
    for y in range(W):
        t = (y / (W - 1)) ** 0.85
        c = tuple(int(BG_TOP[i] + (BG_BOT[i] - BG_TOP[i]) * t) for i in range(3))
        d.line([(0, y), (W, y)], fill=c)

    # 三张叠放的卡片（后画的盖住前面那张的下半部分 → 形成「一叠」的台阶感）
    # 几何按 1024 空间手算：卡片 640×470，横向 192..832；纵向三张各错开 78，
    # 总高 202..828（视觉中心 515 ≈ 画布中心），四周留白约 190 —— iOS 图标不能贴边也不能太小。
    cards = [
        (192, 202, 832, 672, CARD_BACK, CARD_STROKE),
        (192, 280, 832, 750, CARD_MID, CARD_STROKE),
        (192, 358, 832, 828, ACCENT, None),
    ]
    for x0, y0, x1, y1, fill, stroke in cards:
        d.rounded_rectangle(
            [px(x0), px(y0), px(x1) - 1, px(y1) - 1],
            radius=px(60),
            fill=fill,
            outline=stroke,
            width=px(2) if stroke else 0,
        )

    # 最上面那张卡里放 2×2 宫格（就是 App 自己的素材网格）。
    # 选它而不是「山+太阳」这种通用图片图元：宫格天然对称、缩到 60px 仍清晰，
    # 而且它说的正是这个 App 在做的事，不是任意一个相册。
    s, gap, r = 96, 30, 24
    x0 = 512 - (s * 2 + gap) // 2
    y0 = 593 - (s * 2 + gap) // 2
    for row in range(2):
        for col in range(2):
            x = x0 + col * (s + gap)
            y = y0 + row * (s + gap)
            d.rounded_rectangle(
                [px(x), px(y), px(x + s) - 1, px(y + s) - 1],
                radius=px(r),
                fill=INK,
            )

    img = img.resize((1024, 1024), Image.LANCZOS)

    OUT.mkdir(parents=True, exist_ok=True)
    # Xcode 14+ 只需一张 1024 单尺寸图（AppIcon 的 universal 槽位）
    img.save(OUT / "icon-1024.png", "PNG")
    img.save(ROOT / "Resources" / "icon-preview.png", "PNG")
    print("wrote", OUT / "icon-1024.png")


if __name__ == "__main__":
    main()
