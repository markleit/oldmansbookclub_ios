#!/usr/bin/env python3
"""Generate original artwork for the App Store screenshot staging: book covers for public-domain
titles, member avatars, and a 'photo' of a highlighted book page. Nothing borrowed, nothing real.
    python3 scripts/appstore/make_assets.py   → scripts/appstore/assets/*.jpg|png
"""
import math, os, random
from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "assets")
BASK = "/System/Library/Fonts/Supplemental/Baskerville.ttc"   # 0 regular, 1 bold, 2 italic
SANS = "/System/Library/Fonts/SFNS.ttf"
ROUND = "/System/Library/Fonts/SFNSRounded.ttf"

# title, author, background, ink, accent, ornament
BOOKS = {
    "moby-dick":        ("MOBY-DICK", "Herman Melville", "#123247", "#F2E8D5", "#C9A15B", "waves"),
    "treasure-island":  ("TREASURE\nISLAND", "Robert Louis Stevenson", "#7A2E1F", "#F6E7C8", "#E3B04B", "compass"),
    "three-musketeers": ("THE THREE\nMUSKETEERS", "Alexandre Dumas", "#1F3D2B", "#EFE6CF", "#C8A04A", "swords"),
    "twenty-years":     ("TWENTY\nYEARS AFTER", "Alexandre Dumas", "#2B2440", "#EEE4CC", "#C8A04A", "swords"),
    "frankenstein":     ("FRANKEN-\nSTEIN", "Mary Shelley", "#1B1B1F", "#D9E4D0", "#7FA36B", "bolt"),
    "monte-cristo":     ("THE COUNT\nOF MONTE\nCRISTO", "Alexandre Dumas", "#5B1E2D", "#F3E3C3", "#D4AA55", "diamond"),
    "twenty-thousand":  ("20,000\nLEAGUES\nUNDER THE SEA", "Jules Verne", "#0E4D5C", "#E6F0EA", "#E0B65A", "waves"),
    "sherlock":         ("SHERLOCK\nHOLMES", "Arthur Conan Doyle", "#3A2A1C", "#F1E4CB", "#C99A4E", "diamond"),
}

MEMBERS = {"Walt": "#C0603A", "Hank": "#2E6E8E", "Earl": "#6B8E3A", "Gus": "#8A4F9E", "Frank": "#B08A2E"}


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


def serif(size, bold=False, italic=False):
    return font(BASK, size, (1 if bold else 0) + (2 if italic else 0))


def ornament(d, kind, cx, cy, color, s):
    if kind == "waves":
        for row in range(3):
            pts = [(cx - 2.2 * s + x, cy + row * 0.5 * s + math.sin(x / s * 3.2) * 0.18 * s) for x in range(int(4.4 * s))]
            d.line(pts, fill=color, width=max(3, s // 14))
    elif kind == "compass":
        d.ellipse([cx - s, cy - s, cx + s, cy + s], outline=color, width=max(3, s // 14))
        d.polygon([(cx, cy - s * 0.9), (cx + s * 0.18, cy), (cx, cy + s * 0.9), (cx - s * 0.18, cy)], fill=color)
        d.polygon([(cx - s * 0.9, cy), (cx, cy - s * 0.18), (cx + s * 0.9, cy), (cx, cy + s * 0.18)], outline=color)
    elif kind == "swords":
        for sign in (-1, 1):
            d.line([(cx - sign * s, cy + s), (cx + sign * s, cy - s)], fill=color, width=max(4, s // 10))
            d.line([(cx - sign * s * 0.55 - s * 0.25, cy + s * 0.55 - sign * s * 0.25),
                    (cx - sign * s * 0.55 + s * 0.25, cy + s * 0.55 + sign * s * 0.25)], fill=color, width=max(4, s // 10))
    elif kind == "bolt":
        d.polygon([(cx + s * 0.15, cy - s), (cx - s * 0.5, cy + s * 0.1), (cx - s * 0.05, cy + s * 0.1),
                   (cx - s * 0.25, cy + s), (cx + s * 0.5, cy - s * 0.15), (cx + s * 0.05, cy - s * 0.15)], fill=color)
    elif kind == "diamond":
        d.polygon([(cx, cy - s), (cx + s * 0.7, cy), (cx, cy + s), (cx - s * 0.7, cy)], outline=color, width=max(3, s // 14))
        d.polygon([(cx, cy - s * 0.5), (cx + s * 0.35, cy), (cx, cy + s * 0.5), (cx - s * 0.35, cy)], fill=color)


def cover(key):
    title, author, bg, ink, accent, orn = BOOKS[key]
    W, H = 800, 1200
    img = Image.new("RGB", (W, H), bg)
    d = ImageDraw.Draw(img)
    # subtle vertical texture + spine shadow, like a cloth cover
    rnd = random.Random(key)
    for x in range(0, W, 3):
        a = rnd.randint(0, 10)
        d.line([(x, 0), (x, H)], fill=tuple(max(0, c - a) for c in Image.new("RGB", (1, 1), bg).getpixel((0, 0))))
    d.rectangle([40, 40, W - 40, H - 40], outline=accent, width=6)
    d.rectangle([58, 58, W - 58, H - 58], outline=accent, width=2)
    lines = title.split("\n")
    size = 124
    while size > 40 and max(d.textlength(l, font=serif(size, bold=True)) for l in lines) > W - 200:
        size -= 2
    f = serif(size, bold=True)
    total = len(lines) * size * 1.12
    y = 300 - total / 2 + (60 if len(lines) == 1 else 0)
    for line in lines:
        w = d.textlength(line, font=f)
        d.text(((W - w) / 2, y), line, font=f, fill=ink)
        y += size * 1.12
    ornament(d, orn, W // 2, 760, accent, 120)
    fa = serif(54, italic=True)
    w = d.textlength(author, font=fa)
    d.text(((W - w) / 2, H - 200), author, font=fa, fill=ink)
    img.save(os.path.join(OUT, f"cover-{key}.jpg"), quality=92)


def avatar(name, color):
    S = 600
    img = Image.new("RGB", (S, S), color)
    d = ImageDraw.Draw(img)
    # soft diagonal light, then the initial
    for i in range(S):
        a = int(40 * i / S)
        d.line([(0, i), (S, i)], fill=tuple(min(255, c + 40 - a) for c in Image.new("RGB", (1, 1), color).getpixel((0, 0))))
    f = font(ROUND, 300)
    ch = name[0]
    bbox = d.textbbox((0, 0), ch, font=f)
    d.text(((S - (bbox[2] - bbox[0])) / 2 - bbox[0], (S - (bbox[3] - bbox[1])) / 2 - bbox[1]), ch, font=f, fill="white")
    img.save(os.path.join(OUT, f"avatar-{name.lower()}.jpg"), quality=92)


PAGE = ("Call me Ishmael. Some years ago—never mind how long precisely—having little or no money in my "
        "purse, and nothing particular to interest me on shore, I thought I would sail about a little and "
        "see the watery part of the world. It is a way I have of driving off the spleen and regulating the "
        "circulation. Whenever I find myself growing grim about the mouth; whenever it is a damp, drizzly "
        "November in my soul; whenever I find myself involuntarily pausing before coffin warehouses, and "
        "bringing up the rear of every funeral I meet; and especially whenever my hypos get such an upper "
        "hand of me, that it requires a strong moral principle to prevent me from deliberately stepping into "
        "the street, and methodically knocking people's hats off—then, I account it high time to get to sea "
        "as soon as I can.")


def page_photo():
    W, H = 1500, 1500
    paper = Image.new("RGB", (1180, 1500), "#F4ECD8")
    d = ImageDraw.Draw(paper)
    fh, fb = serif(40), serif(46)
    d.text((110, 120), "CHAPTER 1", font=fh, fill="#5A4A36")
    d.text((110, 175), "Loomings.", font=serif(50, italic=True), fill="#3A2E22")
    words, lines, cur = PAGE.split(), [], ""
    for w in words:
        if d.textlength(cur + " " + w, font=fb) > 960:
            lines.append(cur.strip()); cur = w
        else:
            cur += " " + w
    lines.append(cur.strip())
    y = 290
    for i, line in enumerate(lines):
        if i == 0:   # highlighter over "Call me Ishmael."
            hw = d.textlength("Call me Ishmael.", font=fb)
            d.rounded_rectangle([104, y - 2, 110 + hw + 8, y + 56], radius=10, fill="#F5E063")
        d.text((110, y), line, font=fb, fill="#2B241C")
        y += 66
    d.text((560, 1400), "1", font=fh, fill="#7A6A54")
    # lay the page on a wooden table at a slight angle, with a soft shadow — reads as a photo
    table = Image.new("RGB", (W, H), "#6B4A2E")
    td = ImageDraw.Draw(table)
    rnd = random.Random(7)
    for y0 in range(0, H, 6):
        td.line([(0, y0), (W, y0 + rnd.randint(-8, 8))], fill=(100 + rnd.randint(-12, 12), 68 + rnd.randint(-10, 10), 42))
    shadow = Image.new("RGBA", (paper.width + 60, paper.height + 60), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle([30, 30, paper.width + 30, paper.height + 30], fill=(0, 0, 0, 140))
    shadow = shadow.filter(ImageFilter.GaussianBlur(22)).rotate(-4, expand=True)
    p = paper.convert("RGBA").rotate(-4, expand=True, resample=Image.BICUBIC)
    table.paste(shadow, ((W - shadow.width) // 2 + 18, (H - shadow.height) // 2 + 24), shadow)
    table.paste(p, ((W - p.width) // 2, (H - p.height) // 2), p)
    table.save(os.path.join(OUT, "photo-page.jpg"), quality=90)


if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for k in BOOKS: cover(k)
    for n, c in MEMBERS.items(): avatar(n, c)
    page_photo()
    print("\n".join(sorted(os.listdir(OUT))))
