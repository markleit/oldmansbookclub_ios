#!/usr/bin/env python3
"""Frame raw screenshots with a caption for the App Store.
    python3 scripts/appstore/compose.py <raw-dir> <out-dir> <iphone|ipad>
Raw shots come from capture.sh; output is Apple's exact size for the device class.
"""
import os, sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

SANS = "/System/Library/Fonts/SFNS.ttf"
BASK = "/System/Library/Fonts/Supplemental/Baskerville.ttc"

# order, raw name, headline, subline
SHOTS = [
    ("chat-newest",   "Talk it through.",               "Voice messages, photos and texts —\nyour book club between meetings."),
    ("library",       "Every book, one shelf.",          "What you're reading, what's next,\nand everything you've finished."),
    ("chat-oldest",   "Share the page that got you.",    "Photos, replies and reactions\nin every book's discussion."),
    ("chat-menu",     "React, reply, save.",             "Hold any message for quick\nreactions and more."),
    ("voice-playing", "Listen at your own pace.",        "Speed up voice messages, or play\nthem on your speakers or in the car."),
]
SIZES = {"iphone": (1320, 2868), "ipad": (2064, 2752)}
IPAD_SHOTS = {"chat-newest", "library"}   # the iPad layout is the iPhone's, wider: two shots, not five
TOP, BOTTOM = (18, 50, 71), (12, 31, 44)        # deep sea blue, darker at the foot
GOLD = (201, 161, 91)


def font(path, size, index=0):
    return ImageFont.truetype(path, size, index=index)


def background(W, H):
    bg = Image.new("RGB", (W, H))
    d = ImageDraw.Draw(bg)
    for y in range(H):
        t = y / H
        d.line([(0, y), (W, y)], fill=tuple(int(TOP[i] + (BOTTOM[i] - TOP[i]) * t) for i in range(3)))
    return bg


def rounded(im, r):
    mask = Image.new("L", im.size, 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, im.width - 1, im.height - 1], radius=r, fill=255)
    out = im.convert("RGBA"); out.putalpha(mask)
    return out


def frame(raw, headline, subline, W, H, ipad):
    bg = background(W, H)
    d = ImageDraw.Draw(bg)
    hsize, ssize = (118, 54) if not ipad else (128, 58)
    while hsize > 60 and d.textlength(headline, font=font(BASK, hsize, 1)) > W * 0.88:
        hsize -= 2
    fh, fs = font(BASK, hsize, 1), font(SANS, ssize)
    y = int(H * (0.065 if not ipad else 0.05))
    w = d.textlength(headline, font=fh)
    d.text(((W - w) / 2, y), headline, font=fh, fill="white")
    y += int(hsize * 1.25)
    d.line([(W / 2 - 60, y), (W / 2 + 60, y)], fill=GOLD, width=5)
    y += 40
    for line in subline.split("\n"):
        w = d.textlength(line, font=fs)
        d.text(((W - w) / 2, y), line, font=fs, fill=(214, 224, 232))
        y += int(ssize * 1.3)
    # the screenshot: scaled, rounded like the device, soft shadow, running off the bottom edge
    scale = 0.80 if not ipad else 0.78
    shot = Image.open(raw).convert("RGB")
    if ipad:
        # iPadOS shows the app's name in the status bar — the dev build's "OMBC (DEV)". Paint just
        # that label out with the bar's own colour; time, date and icons stay as captured.
        x0, x1 = 336, 530
        px = shot.load()
        for y in range(12, 67):   # blend each row across from its neighbours: invisible over a blur too
            a, b = px[x0 - 1, y], px[x1 + 1, y]
            for x in range(x0, x1 + 1):
                t = (x - x0) / (x1 - x0)
                px[x, y] = tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))
    sw = int(W * scale); sh = int(shot.height * sw / shot.width)
    shot = rounded(shot.resize((sw, sh), Image.LANCZOS), int(sw * (0.12 if not ipad else 0.035)))
    top = y + int(H * 0.035)
    sx = (W - sw) // 2
    shadow = Image.new("RGBA", (sw + 160, sh + 160), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([80, 80, sw + 80, sh + 80], radius=int(sw * 0.1), fill=(0, 0, 0, 150))
    shadow = shadow.filter(ImageFilter.GaussianBlur(40))
    bg.paste(shadow, (sx - 80, top - 60), shadow)
    border = Image.new("RGBA", (sw + 16, sh + 16), (0, 0, 0, 0))
    ImageDraw.Draw(border).rounded_rectangle([0, 0, sw + 15, sh + 15], radius=int(sw * (0.12 if not ipad else 0.035)) + 8, fill=(8, 18, 26, 255))
    bg.paste(border, (sx - 8, top - 8), border)
    bg.paste(shot, (sx, top), shot)
    return bg


def main():
    raw_dir, out_dir, kind = sys.argv[1], sys.argv[2], sys.argv[3]
    W, H = SIZES[kind]
    os.makedirs(out_dir, exist_ok=True)
    n = 0
    for name, headline, subline in SHOTS:
        if kind == "ipad" and name not in IPAD_SHOTS:
            continue
        raw = os.path.join(raw_dir, f"{name}.png")
        if not os.path.exists(raw):
            print("missing", name); continue
        n += 1
        out = os.path.join(out_dir, f"{n:02d}-{name}.png")
        frame(raw, headline, subline, W, H, kind == "ipad").save(out)
        print(out)


if __name__ == "__main__":
    main()
