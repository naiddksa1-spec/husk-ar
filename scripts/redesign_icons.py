#!/usr/bin/env python3
"""Reproducible, opaque iPhone app icons. Requires Pillow and CairoSVG."""
from pathlib import Path
import io
from PIL import Image
import cairosvg

ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / "src/app/Husk"
ART = ROOT / "design"

def svg(background, foreground, secondary):
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
<rect width="1024" height="1024" fill="{background}"/>
<rect x="204" y="204" width="440" height="440" rx="126" fill="none"
      stroke="{secondary}" stroke-width="64"/>
<rect x="380" y="380" width="440" height="440" rx="126" fill="{background}"
      stroke="{foreground}" stroke-width="64"/>
<path d="M380 518V506a126 126 0 0 1 126-126h12" fill="none"
      stroke="{foreground}" stroke-width="64" stroke-linecap="round"/>
<circle cx="600" cy="600" r="44" fill="{foreground}"/>
</svg>'''

def main():
    ART.mkdir(exist_ok=True)
    palettes = {
        "default": ("#6e45b3", "#fcf9ff", "#cbb8eb"),
        "dark": ("#292133", "#dcc8f4", "#827095"),
        "tinted": ("#625568", "#f7f0fa", "#b6a9bc"),
        "clearlight": ("#f3eef8", "#6e45b3", "#b9a2d4"),
        "cleardark": ("#292133", "#dcc8f4", "#827095"),
        "tintedlight": ("#eee7f2", "#68516f", "#b5a3bd"),
        "tinteddark": ("#302633", "#ecdcf1", "#89748f"),
    }
    images = {}
    for name, palette in palettes.items():
        source = svg(*palette)
        (ART / f"icon-{name}.svg").write_text(source)
        images[name] = Image.open(io.BytesIO(cairosvg.svg2png(
            bytestring=source.encode(), output_width=1024, output_height=1024))).convert("RGB")
    primary = APP / "Assets.xcassets/AppIcon.appiconset"
    for kind, file in [("default","Icon-Default.png"), ("dark","Icon-Dark.png"),
                       ("tinted","Icon-Tinted.png")]:
        images[kind].save(primary/file, optimize=True)
    for variant, kind in [("ClearLight","clearlight"),("ClearDark","cleardark"),
                          ("TintedLight","tintedlight"),("TintedDark","tinteddark")]:
        folder = APP / f"Assets.xcassets/AppIcon{variant}.appiconset"
        for name in ("Icon-1024.png", "Icon.png"):
            images[kind].save(folder/name, optimize=True)
    for kind in ("default","dark","clearlight","cleardark","tintedlight","tinteddark"):
        images[kind].resize((256,256), Image.Resampling.LANCZOS).save(
            APP / f"Resources/icon-{kind}.png", optimize=True)
    images["default"].save(ART/"ios-app-icon.png", optimize=True)
    print("Redesigned all primary and alternate icon assets and bundled previews.")

if __name__ == "__main__":
    main()
