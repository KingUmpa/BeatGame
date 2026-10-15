"""Cuts assets/images/device.png (a picture of the device on white) into what the game draws:

    assets/images/device_body.png   the body with its pad wells empty, and its shadow
    assets/images/device_pads.png   the four pads alone (the game tints each with its light)
    assets/images/device.json       where the pads are in those two (pixels), and the color
                                    of the picture's border, which the game's background takes

    python3 tools/make_device.py [picture.png]      (default: assets/images/device_beatbuilder.png)

Needs numpy and Pillow. The picture must have a white or grey background and white pads on a
body that is dark or colored (the black device.png, the translucent blue device_blue.png).
"""
import json, os, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DIR = os.path.join(ROOT, "assets/images")
SOURCE = "device_beatbuilder.png"
LIGHT = 110      # brighter than this (and not colored) is background or pad
BODY = 70        # darker than this is surely the body (its shadow on the table is lighter)
COLORED = 36     # so is anything this far from grey (max - min of r g b): a colored body
FADE = 24        # pixels over which the last of the shadow fades out at the picture's edge


def main():
    src = Image.open(sys.argv[1] if len(sys.argv) > 1 else os.path.join(DIR, SOURCE)).convert("RGB")
    W, H = src.size
    px = np.asarray(src).astype(int)
    colored = px.max(axis=2) - px.min(axis=2) > COLORED
    dark = (np.asarray(src.convert("L")) <= LIGHT) | colored

    # the background: what lies outside the body. The body is convex, so in every row and
    # column it is everything before the first dark pixel and after the last
    def beyond(d):
        seen = np.maximum.accumulate(d, axis=1)
        return ~(seen & np.maximum.accumulate(d[:, ::-1], axis=1)[:, ::-1])
    body = (np.asarray(src.convert("L")) <= BODY) | colored
    outside = beyond(body) | beyond(body.T).T
    a = np.where(outside, 128, np.where(dark, 0, 255)).astype(np.uint8)

    # the pads: the light areas left. Specks (highlights on the body) are opened away, then the
    # picture is cut in four round the middle of what remains: one pad a quarter
    inner = Image.fromarray(((a == 255) * 255).astype(np.uint8))
    solid = np.asarray(inner.filter(ImageFilter.MinFilter(15)).filter(ImageFilter.MaxFilter(15))) > 0
    # (lettering on the body is light too, but nowhere near as big as a pad: only what is
    # left of a much coarser opening, and what touches it, is a pad)
    big = inner.filter(ImageFilter.MinFilter(61)).filter(ImageFilter.MaxFilter(61)).filter(ImageFilter.MaxFilter(15))
    solid = solid & (np.asarray(big) > 0)
    ys, xs = np.nonzero(solid)
    cx, cy = (xs.min() + xs.max()) // 2, (ys.min() + ys.max()) // 2
    # the cuts go down the gaps between the pads: the emptiest column and row near the middle
    cx = cx - 80 + int(np.argmin(solid[:, cx - 80:cx + 80].sum(axis=0)))
    cy = cy - 80 + int(np.argmin(solid[cy - 80:cy + 80, :].sum(axis=1)))
    pads = []
    for qy in (slice(0, cy), slice(cy, H)):
        for qx in (slice(0, cx), slice(cx, W)):
            m = np.zeros_like(solid)
            m[qy, qx] = solid[qy, qx]
            pads.append(m)
    assert all(m.sum() > 10000 for m in pads), "expected four pads"

    def box(m):
        ys, xs = np.nonzero(m)
        return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1

    # (already Q W / A S: top row then bottom row, left to right)
    # each pad as a solid shape, a little past its edge so the anti-aliased rim comes with it
    shapes = []
    for m in pads:
        im = Image.fromarray((m * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.MinFilter(5))
        shapes.append(im)
    all_pads = np.max([np.asarray(s) for s in shapes], axis=0)

    # the game's background is the color of the picture's border ("background")
    ring = np.concatenate([np.asarray(src)[:6].reshape(-1, 3), np.asarray(src)[-6:].reshape(-1, 3),
                           np.asarray(src)[:, :6].reshape(-1, 3), np.asarray(src)[:, -6:].reshape(-1, 3)])
    background = [round(float(v) / 255, 4) for v in np.median(ring, axis=0)]
    # round the body the table is see-through and the shadow is black, as dark as it is in
    # the picture: over that background color it looks the same, and it has no edge
    lum = np.asarray(src.convert("L")).astype(float)
    shade = np.clip((np.mean(background) * 255 - lum - 1.5) / (np.mean(background) * 255), 0, 1)
    yy, xx = np.mgrid[0:H, 0:W]
    edge = np.minimum(np.minimum(xx, W - 1 - xx), np.minimum(yy, H - 1 - yy))
    shade = shade * np.clip(edge / FADE, 0, 1)
    body_a = Image.fromarray((np.where(outside, shade, 1) * 255).astype(np.uint8))
    rgb = np.asarray(src).copy()
    rgb[outside] = 0
    # empty the wells: the colour of the gap between the pads, well past each pad's edge
    well = np.asarray(Image.fromarray(all_pads).filter(ImageFilter.MaxFilter(13))) > 0
    x0, y0, x1, y1 = box(all_pads > 0)
    gap = rgb[(y0 + y1) // 2 - 2:(y0 + y1) // 2 + 2, x0 + 40:x0 + 80].reshape(-1, 3)
    floor = np.percentile(rgb[~outside & ~well].reshape(-1, 3), 10, axis=0)
    well = well & ~outside
    rgb[well] = np.minimum(gap.mean(axis=0), floor).astype(np.uint8)
    body = Image.fromarray(np.dstack([rgb, np.asarray(body_a)]))

    pad_a = Image.fromarray(all_pads).filter(ImageFilter.GaussianBlur(0.8))
    padsimg = Image.fromarray(np.dstack([np.where(np.asarray(pad_a)[..., None] > 0, np.asarray(src), 255), np.asarray(pad_a)]))

    crop = (0, 0, W, H)
    body.crop(crop).save(os.path.join(DIR, "device_body.png"), optimize=True)
    padsimg.crop(crop).save(os.path.join(DIR, "device_pads.png"), optimize=True)
    meta = {"width": crop[2] - crop[0], "height": crop[3] - crop[1], "background": background, "pads": []}
    for s in shapes:
        px0, py0, px1, py1 = box(np.asarray(s) > 0)
        meta["pads"].append({"x": px0 - crop[0] - 2, "y": py0 - crop[1] - 2, "w": px1 - px0 + 4, "h": py1 - py0 + 4})
    with open(os.path.join(DIR, "device.json"), "w") as f:
        json.dump(meta, f, indent=2)
    print(json.dumps(meta))


main()
