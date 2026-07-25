#!/usr/bin/env python3
"""Extract the peeking Kiwi decoration from the supplied popup mockup."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parent.parent
SOURCE = (
    ROOT
    / "Assets"
    / "Source"
    / "TaskBreakShell"
    / "task-break-shell.png"
)
OUTPUT = ROOT / "Assets" / "Frames" / "task-break-peek.png"

# The mockup is a fixed 2245×1587 canvas. This crop contains only the visible
# character above the card; the native card will cover its flat lower edge.
PEEK_BOUNDS = (1030, 230, 1370, 405)


def main() -> None:
    source = Image.open(SOURCE).convert("RGB")
    if source.size != (2245, 1587):
        raise ValueError(f"Unexpected task popup mockup size: {source.size}")

    crop = source.crop(PEEK_BOUNDS)
    rgb = np.asarray(crop)
    minimum = np.min(rgb, axis=2)
    foreground = minimum < 250
    mask = Image.fromarray(foreground.astype(np.uint8) * 255, mode="L")
    mask = mask.filter(ImageFilter.MinFilter(3))
    mask = mask.filter(ImageFilter.GaussianBlur(0.45))

    rgba = np.dstack((rgb, np.asarray(mask))).astype(np.uint8)
    result = Image.fromarray(rgba, mode="RGBA")
    visible_bounds = result.getchannel("A").getbbox()
    if visible_bounds is None:
        raise ValueError("Could not find the peeking Kiwi in the mockup")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    result.crop(visible_bounds).save(OUTPUT, optimize=True)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
