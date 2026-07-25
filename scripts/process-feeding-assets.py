#!/usr/bin/env python3
"""Crop the supplied feeding artwork and remove its opaque white canvas."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "Assets" / "Source" / "Feeding"
OUTPUT_DIR = ROOT / "Assets" / "Frames"

ASSETS = {
    "food-bag-source.png": "feed-bag.png",
    "food-pile-source.png": "feed-food.png",
}
EMPTY_BAG_SOURCE = SOURCE_DIR / "food-bag-empty-source.png"
ACTION_SOURCE_DIR = SOURCE_DIR / "Action"
ACTION_SCALE = 0.845


def process(source: Path, destination: Path) -> None:
    image = Image.open(source).convert("RGBA")
    pixels = np.asarray(image)
    rgb = pixels[:, :, :3]

    # Both supplied drawings sit on an opaque white canvas. Build a soft alpha
    # edge from their distance to white, retaining the pale yellow food pieces.
    distance_from_white = 255 - rgb.min(axis=2)
    foreground = distance_from_white > 5
    ys, xs = np.where(foreground)
    if not len(xs):
        raise ValueError(f"No foreground found in {source}")

    padding = 20
    left = max(int(xs.min()) - padding, 0)
    top = max(int(ys.min()) - padding, 0)
    right = min(int(xs.max()) + padding + 1, image.width)
    bottom = min(int(ys.max()) + padding + 1, image.height)

    cropped_rgb = rgb[top:bottom, left:right]
    cropped_distance = distance_from_white[top:bottom, left:right]
    alpha = np.clip(
        (cropped_distance.astype(np.float32) - 2) / 12 * 255,
        0,
        255,
    ).astype(np.uint8)
    alpha_image = Image.fromarray(alpha, mode="L").filter(
        ImageFilter.GaussianBlur(radius=0.35)
    )

    result = Image.fromarray(cropped_rgb, mode="RGB").convert("RGBA")
    result.putalpha(alpha_image)
    result.save(destination, optimize=True)
    print(f"{source.name} -> {destination.name} {result.size}")


def crop_transparent(
    source: Path,
    destination: Path,
    padding: int = 20,
) -> None:
    image = Image.open(source).convert("RGBA")
    alpha = np.asarray(image)[:, :, 3]
    ys, xs = np.where(alpha > 5)
    if not len(xs):
        raise ValueError(f"No visible pixels found in {source}")
    box = (
        max(int(xs.min()) - padding, 0),
        max(int(ys.min()) - padding, 0),
        min(int(xs.max()) + padding + 1, image.width),
        min(int(ys.max()) + padding + 1, image.height),
    )
    result = image.crop(box)
    result.save(destination, optimize=True)
    print(f"{source.name} -> {destination.name} {result.size}")


def process_action_frames() -> None:
    sources = [
        ACTION_SOURCE_DIR / f"action-{index:02d}.png"
        for index in range(1, 5)
    ]
    images = [Image.open(path).convert("RGBA") for path in sources]
    alpha_masks = [np.asarray(image)[:, :, 3] > 5 for image in images]
    union = np.logical_or.reduce(alpha_masks)
    ys, xs = np.where(union)
    padding = 20
    box = (
        max(int(xs.min()) - padding, 0),
        max(int(ys.min()) - padding, 0),
        min(int(xs.max()) + padding + 1, images[0].width),
        min(int(ys.max()) + padding + 1, images[0].height),
    )
    for index, (source, image) in enumerate(
        zip(sources, images),
        start=1,
    ):
        # The supplied drawings face left. Kiwi's renderer expects all
        # authored motion frames to face right and mirrors them at runtime.
        cropped = image.crop(box).transpose(
            Image.Transpose.FLIP_LEFT_RIGHT
        )
        # The supplied action drawings are cropped much more tightly than the
        # idle sprites. Normalize them to the idle bird's visible size while
        # preserving a fixed foot baseline so switching poses never zooms Kiwi.
        normalized_size = (
            round(cropped.width * ACTION_SCALE),
            round(cropped.height * ACTION_SCALE),
        )
        normalized = cropped.resize(
            normalized_size,
            Image.Resampling.LANCZOS,
        )
        result = Image.new("RGBA", cropped.size, (0, 0, 0, 0))
        result.alpha_composite(
            normalized,
            (
                (cropped.width - normalized.width) // 2,
                cropped.height - normalized.height,
            ),
        )
        destination = OUTPUT_DIR / f"feed-action-{index:02d}.png"
        result.save(destination, optimize=True)
        print(f"{source.name} -> {destination.name} {result.size}")


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for source_name, output_name in ASSETS.items():
        process(SOURCE_DIR / source_name, OUTPUT_DIR / output_name)
    crop_transparent(
        EMPTY_BAG_SOURCE,
        OUTPUT_DIR / "feed-bag-empty.png",
    )
    process_action_frames()


if __name__ == "__main__":
    main()
