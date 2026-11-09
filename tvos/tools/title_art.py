#!/usr/bin/env python3
"""Cuts the Home screen icon's artwork out of a screenshot of the game's title screen ("Press START to begin").

    python -I tvos/tools/title_art.py <screenshot.png> <out dir>      (tvos/tv.sh art does this)

The screenshot is your own copy of the game running on your Apple TV (xcrun devicectl device capture screenshot), so the
artwork is EA's from your own game: for your own Apple TV, never committed. Writes <out>/title.png (the scene, above the
"Press START" and copyright lines), <out>/logo.png (the Need for Speed Most Wanted logo with transparency) and
<out>/art.json (where the logo sits in title.png). tvos/tools/make_icons.py lays them out as the icon's layers."""
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageOps

# The title screen's layout at 3840x2160 (any 16:9 screenshot is scaled to it): the logo's box, and the scene kept for
# the icon (5:3, the icon's shape, above the text lines).
LOGO = (1620, 140, 3330, 520)
SCENE = (500, 0, 3333, 1700)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    shot = Image.open(sys.argv[1]).convert("RGB").resize((3840, 2160), Image.LANCZOS)
    out = Path(sys.argv[2])
    out.mkdir(parents=True, exist_ok=True)
    logo = shot.crop(LOGO)
    # The logo is black lettering on a white paint splash: the splash (bright pixels, small gaps closed, holes filled)
    # is the mask.
    white = ImageOps.grayscale(logo).point(lambda v: 255 if v > 165 else 0)
    closed = white.filter(ImageFilter.MaxFilter(21)).filter(ImageFilter.MinFilter(21))
    pad = Image.new("L", (closed.width + 2, closed.height + 2), 0)
    pad.paste(closed, (1, 1))
    ImageDraw.floodfill(pad, (0, 0), 128)
    mask = pad.crop((1, 1, closed.width + 1, closed.height + 1)).point(lambda v: 0 if v == 128 else 255)
    mask = mask.filter(ImageFilter.MinFilter(3)).filter(ImageFilter.GaussianBlur(1.5))
    cut = logo.convert("RGBA")
    cut.putalpha(mask)
    # The sky's yellow glow touches the splash's lower left: not part of the logo.
    px, hsv = cut.load(), cut.convert("RGB").convert("HSV").load()
    for y in range(cut.height // 2, cut.height):
        for x in range(min(330, cut.width)):
            if hsv[x, y][1] > 55:
                px[x, y] = px[x, y][:3] + (0,)
    box = cut.getchannel("A").point(lambda v: 255 if v > 20 else 0).getbbox()
    cut = cut.crop(box)
    cut.save(out / "logo.png")
    shot.crop(SCENE).save(out / "title.png")
    at = (LOGO[0] + box[0] - SCENE[0], LOGO[1] + box[1] - SCENE[1])
    (out / "art.json").write_text(json.dumps({"logo_at": at, "scene": [SCENE[2] - SCENE[0], SCENE[3] - SCENE[1]]}))
    print(f"title_art: wrote {out}/logo.png, title.png, art.json")


if __name__ == "__main__":
    main()
