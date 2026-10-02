#!/usr/bin/env python3
"""Build Handle's macOS app icon set from the Figma export of the icon frame.

    python3 tools/make_icon.py <figma_frame_export.png>

The source is the icon frame exported from Figma at 4x (black body, translucent
handle glyph). The glyph is lifted off the black body (white with alpha = brightness),
then drawn on Apple's macOS icon grid: an 824 px rounded body centred in a 1024 px
canvas with a soft shadow. Every size in the asset catalog is downscaled from that.
Needs Pillow.
"""
import sys, pathlib
from PIL import Image, ImageDraw, ImageFilter

src_path = pathlib.Path(sys.argv[1])
out_dir = pathlib.Path(__file__).resolve().parent.parent / "Handle/Assets.xcassets/AppIcon.appiconset"

CANVAS, BODY, RADIUS = 1024, 824, 185
SS = 2                                    # supersample for smooth edges
src = Image.open(src_path).convert("RGB")
w = src.width

# The glyph: brightness over a pure-black body is exactly its opacity. Everything
# outside the glyph's area (the frame's own corners) is ignored.
lum = src.convert("L")
box = (int(w * 0.14), int(w * 0.26), int(w * 0.86), int(w * 0.72))
glyph_alpha = Image.new("L", src.size, 0)
glyph_alpha.paste(lum.crop(box), box)

size = CANVAS * SS
canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
off, body, rad = (CANVAS - BODY) // 2 * SS, BODY * SS, RADIUS * SS

shadow = Image.new("L", (size, size), 0)
ImageDraw.Draw(shadow).rounded_rectangle((off, off + 10 * SS, off + body, off + body + 10 * SS), rad, fill=80)
shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
canvas.paste(Image.new("RGBA", (size, size), (0, 0, 0, 255)), (0, 0), shadow)

mask = Image.new("L", (size, size), 0)
ImageDraw.Draw(mask).rounded_rectangle((off, off, off + body, off + body), rad, fill=255)
canvas.paste(Image.new("RGBA", (size, size), (0, 0, 0, 255)), (0, 0), mask)

# White everywhere, with the glyph's opacity as the alpha channel (pasting through a
# mask would darken it: the mask would scale colour AND alpha).
alpha = Image.new("L", (size, size), 0)
alpha.paste(glyph_alpha.resize((body, body), Image.LANCZOS), (off, off))
layer = Image.new("RGBA", (size, size), (255, 255, 255, 0))
layer.putalpha(alpha)
canvas = Image.alpha_composite(canvas, layer)

master = canvas.resize((CANVAS, CANVAS), Image.LANCZOS)
names = {16: ["icon_16x16.png"], 32: ["icon_16x16@2x.png", "icon_32x32.png"], 64: ["icon_32x32@2x.png"],
         128: ["icon_128x128.png"], 256: ["icon_128x128@2x.png", "icon_256x256.png"],
         512: ["icon_256x256@2x.png", "icon_512x512.png"], 1024: ["icon_512x512@2x.png"]}
for px, files in names.items():
    img = master if px == CANVAS else master.resize((px, px), Image.LANCZOS)
    for f in files:
        img.save(out_dir / f)
print("wrote", sum(len(v) for v in names.values()), "icons to", out_dir)
