#!/usr/bin/env python3
"""Writes the Apple TV app's asset catalog: the layered app icons tvOS wants and the Top Shelf images.

    python -I tvos/tools/make_icons.py <mac-icon.png> <out/Assets.xcassets> [<art dir>]

Without artwork the picture is the Mac app's own icon (runtime/app_icon.m: a generic speedometer, no game artwork): its
rounded tile floats on the front layer over a dark gradient, with a soft shadow on the middle layer, so the Home screen's
parallax tilt moves it. With artwork from your own copy of the game (an art dir from tvos/tools/title_art.py: the title screen's logo
and scene; EA's artwork, for your own Apple TV, never committed) the logo is the front layer over the title screen."""
import json
import shutil
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter

INFO = {"author": "xcode", "version": 1}


def tile(src):
    """The Mac icon's 824 px rounded tile (the 1024 px canvas has a 100 px margin and a drop shadow)."""
    im = Image.open(src).convert("RGBA")
    k = im.width / 1024
    return im.crop((round(100 * k), round(100 * k), round(924 * k), round(924 * k)))


def back(w, h):
    im = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(im)
    for y in range(h):
        t = y / max(1, h - 1)
        d.line([(0, y), (w, y)], fill=(int(10 + 30 * (1 - t)), int(12 + 36 * (1 - t)), int(20 + 50 * (1 - t))))
    # a low orange glow, like the gauge's needle
    glow = Image.new("L", (w, h), 0)
    ImageDraw.Draw(glow).ellipse([w * 0.15, h * 0.62, w * 0.85, h * 1.25], fill=90)
    glow = glow.filter(ImageFilter.GaussianBlur(h / 8))
    im.paste(Image.new("RGB", (w, h), (255, 120, 40)), (0, 0), glow)
    return im


def placed(icon, w, h, scale):
    side = round(h * scale)
    return icon.resize((side, side), Image.LANCZOS), ((w - side) // 2, (h - side) // 2)


def middle(icon, w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    t, (x, y) = placed(icon, w, h, 0.74)
    shadow = Image.new("RGBA", t.size, (0, 0, 0, 0))
    shadow.putalpha(t.getchannel("A").point(lambda a: a * 150 // 255))
    im.alpha_composite(shadow, (x + h // 60, y + h // 30))
    return im.filter(ImageFilter.GaussianBlur(max(2, h // 40)))


def front(icon, w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    t, pos = placed(icon, w, h, 0.74)
    im.alpha_composite(t, pos)
    return im


def write(path, obj):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2))


def stack(brand, icon, name, w, h, scales):
    base = brand / (name + ".imagestack")
    write(base / "Contents.json", {"info": INFO, "layers": [
        {"filename": "Front.imagestacklayer"}, {"filename": "Middle.imagestacklayer"}, {"filename": "Back.imagestacklayer"}]})
    for layer, make in (("Front", lambda w, h: front(icon, w, h)), ("Middle", lambda w, h: middle(icon, w, h)), ("Back", back)):
        lb = base / (layer + ".imagestacklayer")
        write(lb / "Contents.json", {"info": INFO})
        images = []
        for sc in scales:
            fn = f"{layer.lower()}@{sc}x.png"
            (lb / "Content.imageset").mkdir(parents=True, exist_ok=True)
            make(w * sc, h * sc).save(lb / "Content.imageset" / fn)
            images.append({"idiom": "tv", "filename": fn, "scale": f"{sc}x"})
        write(lb / "Content.imageset" / "Contents.json", {"images": images, "info": INFO})


def shelf(brand, icon, name, w, h):
    iset = brand / (name + ".imageset")
    iset.mkdir(parents=True, exist_ok=True)
    images = []
    for sc in (1, 2):
        im = back(w * sc, h * sc).convert("RGBA")
        im.alpha_composite(middle(icon, w * sc, h * sc))
        im.alpha_composite(front(icon, w * sc, h * sc))
        fn = f"shelf@{sc}x.png"
        im.convert("RGB").save(iset / fn)
        images.append({"idiom": "tv", "filename": fn, "scale": f"{sc}x"})
    write(iset / "Contents.json", {"images": images, "info": INFO})


ART = None   # (logo RGBA, scene RGB, logo's top-left in the scene) from tvos/tools/title_art.py


def art_fit(w, h):
    """Scale and crop offset that make the scene cover a w x h layer, centred."""
    scene = ART[1]
    k = max(w / scene.width, h / scene.height)
    return k, ((scene.width * k - w) / 2, (scene.height * k - h) / 2)


def art_back(w, h):
    k, (ox, oy) = art_fit(w, h)
    im = ART[1].resize((round(ART[1].width * k), round(ART[1].height * k)), Image.LANCZOS)
    im = im.crop((round(ox), round(oy), round(ox) + w, round(oy) + h)).filter(ImageFilter.GaussianBlur(max(1, h / 300)))
    return Image.blend(im, Image.new("RGB", (w, h), (0, 0, 0)), 0.15)


def art_logo(w, h):
    """The logo where the title screen has it (the layers line up; the parallax tilt separates them)."""
    k, (ox, oy) = art_fit(w, h)
    logo = ART[0]
    t = logo.resize((round(logo.width * k), round(logo.height * k)), Image.LANCZOS)
    return t, (round(ART[2][0] * k - ox), round(ART[2][1] * k - oy))


def art_front(w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    t, pos = art_logo(w, h)
    im.alpha_composite(t, pos)
    return im


def art_middle(w, h):
    im = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    t, (x, y) = art_logo(w, h)
    shadow = Image.new("RGBA", t.size, (0, 0, 0, 0))
    shadow.putalpha(t.getchannel("A").point(lambda a: a * 170 // 255))
    im.alpha_composite(shadow, (x + max(1, h // 120), y + max(1, h // 60)))
    return im.filter(ImageFilter.GaussianBlur(max(1, h // 80)))


def main():
    global back, middle, front, ART
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__)
    icon, out = tile(sys.argv[1]), Path(sys.argv[2])
    if len(sys.argv) == 4:
        art = Path(sys.argv[3])
        ART = (Image.open(art / "logo.png").convert("RGBA"), Image.open(art / "title.png").convert("RGB"),
               json.loads((art / "art.json").read_text())["logo_at"])
        back = art_back
        middle = lambda icon, w, h: art_middle(w, h)
        front = lambda icon, w, h: art_front(w, h)
    shutil.rmtree(out, ignore_errors=True)
    brand = out / "App Icon & Top Shelf Image.brandassets"
    write(out / "Contents.json", {"info": INFO})
    stack(brand, icon, "App Icon - Large", 1280, 768, (1,))
    stack(brand, icon, "App Icon - Small", 400, 240, (1, 2))
    shelf(brand, icon, "Top Shelf Image", 1920, 720)
    shelf(brand, icon, "Top Shelf Image Wide", 2320, 720)
    write(brand / "Contents.json", {"assets": [
        {"filename": "App Icon - Large.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon - Small.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"}], "info": INFO})
    print(f"make_icons: wrote {out}")


if __name__ == "__main__":
    main()
