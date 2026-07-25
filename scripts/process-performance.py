#!/usr/bin/env python3
"""Turn the reviewed screen-recording frames into transparent pet sprites."""

from __future__ import annotations

import argparse
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps


ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SOURCE = ROOT / "video_review_frames" / "all"
DEFAULT_OUTPUT = ROOT / "Assets" / "Frames"

FRAME_WIDTH = 420
FRAME_HEIGHT = 480
SOURCE_TOP = 320


def character_bounds(image: Image.Image) -> tuple[int, int, int, int]:
    rgb = np.asarray(image.convert("RGB"))
    foreground = np.min(rgb, axis=2) < 225
    ys, xs = np.nonzero(foreground)
    if len(xs) == 0:
        raise ValueError("Frame does not contain a visible character")
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def remove_white_background(image: Image.Image) -> Image.Image:
    rgb = np.asarray(image.convert("RGB"))
    minimum = np.min(rgb, axis=2)
    spread = np.max(rgb, axis=2) - minimum
    background_candidate = (minimum > 235) | (
        (minimum > 160) & (spread < 14)
    )

    height, width = background_candidate.shape
    background = np.zeros((height, width), dtype=bool)
    queue: deque[tuple[int, int]] = deque()
    for x in range(width):
        if background_candidate[0, x]:
            queue.append((0, x))
        if background_candidate[height - 1, x]:
            queue.append((height - 1, x))
    for y in range(height):
        if background_candidate[y, 0]:
            queue.append((y, 0))
        if background_candidate[y, width - 1]:
            queue.append((y, width - 1))

    while queue:
        y, x = queue.popleft()
        if background[y, x] or not background_candidate[y, x]:
            continue
        background[y, x] = True
        for next_y, next_x in (
            (y - 1, x),
            (y + 1, x),
            (y, x - 1),
            (y, x + 1),
        ):
            if (
                0 <= next_y < height
                and 0 <= next_x < width
                and not background[next_y, next_x]
            ):
                queue.append((next_y, next_x))

    mask = Image.fromarray((~background).astype(np.uint8) * 255, mode="L")
    # Remove the bright compression fringe from the white screen recording,
    # then restore a small antialiased edge for dark and light wallpapers.
    mask = mask.filter(ImageFilter.MinFilter(3))
    mask = mask.filter(ImageFilter.GaussianBlur(0.55))
    alpha = np.asarray(mask)

    foreground = rgb.copy()
    foreground[alpha == 0] = 0
    rgba = np.dstack((foreground, alpha)).astype(np.uint8)
    return Image.fromarray(rgba, mode="RGBA")


def normalize_frame(image: Image.Image) -> Image.Image:
    x0, _, x1, _ = character_bounds(image)
    center_x = round((x0 + x1) / 2)
    left = center_x - FRAME_WIDTH // 2
    crop = image.crop(
        (
            left,
            SOURCE_TOP,
            left + FRAME_WIDTH,
            SOURCE_TOP + FRAME_HEIGHT,
        )
    )
    # The app's existing artwork faces right at scale +1. Mirroring here keeps
    # the new sprites compatible with the same facing-direction transform.
    return remove_white_background(ImageOps.mirror(crop))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        type=Path,
        default=DEFAULT_SOURCE,
        help="Directory containing frame_001.png through frame_061.png",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="Destination Assets/Frames directory",
    )
    args = parser.parse_args()

    source_frames = sorted(args.source.glob("frame_*.png"))
    if len(source_frames) != 61:
        raise ValueError(f"Expected 61 reviewed frames, found {len(source_frames)}")

    args.output.mkdir(parents=True, exist_ok=True)
    for index, source_path in enumerate(source_frames, start=1):
        frame = normalize_frame(Image.open(source_path))
        frame.save(args.output / f"performance-{index:03d}.png", optimize=True)

    print(f"Wrote {len(source_frames)} performance frames to {args.output}")


if __name__ == "__main__":
    main()
