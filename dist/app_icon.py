"""The app icon, drawn once for every platform from one PNG (assets/images/icon.png): the art
centre-cropped square and given rounded corners. Used by fuse_mac.py (.icns) and win_icon.py
(.ico inside the exe), so the Mac and Windows builds show the same icon. Needs Pillow.
"""

CORNER = 185 / 824   # Apple's icon grid: a 185 px corner on the 824 px body


def render(png_path, size=1024, margin=0):
    """RGBA size x size image: the PNG as a rounded square, inset `margin` px on every side
    (macOS icons sit 100 px inside a 1024 canvas; Windows icons fill the frame)."""
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        raise SystemExit("the app icon needs Pillow: py -m pip install pillow")
    body = size - 2 * margin
    ss = 4
    art = Image.open(png_path).convert("RGBA")
    side = min(art.size)
    left, top = (art.width - side) // 2, (art.height - side) // 2
    art = art.crop((left, top, left + side, top + side)).resize((body, body), Image.LANCZOS)
    # the rounded mask is drawn 4x and scaled down so the corners are antialiased
    mask = Image.new("L", (body * ss, body * ss), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, body * ss - 1, body * ss - 1), radius=round(CORNER * body * ss), fill=255)
    art.putalpha(mask.resize((body, body), Image.LANCZOS))
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(art, (margin, margin), art)
    return icon
