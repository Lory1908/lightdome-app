"""Generate offline LightDome PWA icons. Requires Pillow at authoring time only."""
from pathlib import Path
from PIL import Image, ImageDraw
import math

ROOT = Path(__file__).resolve().parents[1] / "web"
ICON_DIR = ROOT / "icons"
ICON_DIR.mkdir(parents=True, exist_ok=True)


def render(size, maskable=False):
    scale = 3
    n = size * scale
    image = Image.new("RGBA", (n, n), (12, 16, 16, 255))
    pixels = image.load()
    cx, cy = n/2, n/2
    width = n * (.23 if maskable else .28)
    # Dark graphite surface with a warm radial halo.
    for y in range(n):
        for x in range(n):
            r = math.hypot(x-cx, y-cy)/width
            strength = max(0, math.exp(-2.5*r*r) * .40)
            pixels[x,y] = (
                int(12+190*strength),
                int(16+133*strength),
                int(16+30*strength),
                255,
            )
    draw = ImageDraw.Draw(image)
    radius = int(n * (.19 if maskable else .23))
    draw.ellipse((cx-radius,cy-radius,cx+radius,cy+radius),
                 fill=(247, 207, 105, 255), outline=(255, 229, 156, 255),
                 width=max(1,int(.009*n)))
    core = int(radius*.63)
    draw.ellipse((cx-core,cy-core,cx+core,cy+core), fill=(255, 236, 183, 255))
    # Concentric contour suggests a compact light dome, without small lettering.
    for factor, alpha in [(1.36, 205), (1.56, 125)]:
        ring = int(radius*factor)
        ring_layer = Image.new("RGBA", (n, n))
        rd = ImageDraw.Draw(ring_layer)
        rd.ellipse((cx-ring,cy-ring,cx+ring,cy+ring),
                   outline=(250, 212, 119, alpha), width=max(2,int(n*.011)))
        image = Image.alpha_composite(image,ring_layer)
    return image.convert("RGB").resize((size,size), Image.Resampling.LANCZOS)


for width in (192,512):
    render(width).save(ICON_DIR / f"Icon-{width}.png")
    render(width,maskable=True).save(ICON_DIR / f"Icon-maskable-{width}.png")
render(180).save(ICON_DIR / "apple-touch-icon.png")
render(64).save(ROOT / "favicon.png")
print("Generated 6 local PWA icons")
