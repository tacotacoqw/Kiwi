#!/usr/bin/env python3
"""Normalize the 21-frame hand-drawn walking sequence for Kiwi."""

from pathlib import Path

import numpy as np
from PIL import Image, ImageOps


ROOT = Path(__file__).resolve().parent.parent
SOURCE_DIR = ROOT / "Assets" / "Source" / "NaturalWalk"
FRAMES_DIR = ROOT / "Assets" / "Frames"
PREVIEW_DIR = ROOT / "Assets" / "Preview"

FRAME_WIDTH = 420
FRAME_HEIGHT = 480
BASELINE = 464
TARGET_MAX_WIDTH = 300
TARGET_MAX_HEIGHT = 280
FRAME_COUNT = 21


def alpha_centroid_x(image: Image.Image) -> float:
    alpha = np.asarray(image.getchannel("A"), dtype=np.float64)
    total = alpha.sum()
    if total <= 0:
        return image.width / 2
    x_coordinates = np.arange(image.width, dtype=np.float64)
    return float((alpha.sum(axis=0) * x_coordinates).sum() / total)


def normalize_frames() -> list[Image.Image]:
    source_paths = [
        SOURCE_DIR / f"frame-{index:02d}.png"
        for index in range(1, FRAME_COUNT + 1)
    ]
    missing = [path.name for path in source_paths if not path.exists()]
    if missing:
        raise ValueError(f"Missing natural walk frames: {', '.join(missing)}")

    sources = [Image.open(path).convert("RGBA") for path in source_paths]
    bounds = [image.getchannel("A").getbbox() for image in sources]
    if any(bound is None for bound in bounds):
        raise ValueError("A natural walk frame has no visible pixels")

    visible_bounds = [bound for bound in bounds if bound is not None]
    maximum_width = max(bound[2] - bound[0] for bound in visible_bounds)
    maximum_height = max(bound[3] - bound[1] for bound in visible_bounds)
    scale = min(
        TARGET_MAX_WIDTH / maximum_width,
        TARGET_MAX_HEIGHT / maximum_height,
    )

    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    normalized: list[Image.Image] = []
    for index, (source, bound) in enumerate(
        zip(sources, visible_bounds),
        start=1,
    ):
        character = source.crop(bound)
        character = character.resize(
            (
                round(character.width * scale),
                round(character.height * scale),
            ),
            Image.Resampling.LANCZOS,
        )

        # The supplied drawings face left. Kiwi's renderer treats the
        # unmirrored asset as facing right, so normalize the source once here.
        character = ImageOps.mirror(character)
        paste_x = round(FRAME_WIDTH / 2 - alpha_centroid_x(character))
        paste_y = BASELINE - character.height
        canvas = Image.new(
            "RGBA",
            (FRAME_WIDTH, FRAME_HEIGHT),
            (0, 0, 0, 0),
        )
        canvas.alpha_composite(character, (paste_x, paste_y))
        canvas.save(
            FRAMES_DIR / f"natural-walk-{index:02d}.png",
            optimize=True,
        )
        normalized.append(canvas)

    return normalized


def write_preview(frames: list[Image.Image]) -> None:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    stride_frames = [8, 13, 12, 11, 10, 9]
    sequence = [
        *range(0, 8),
        *stride_frames,
        *stride_frames,
        *stride_frames,
        *stride_frames,
        *range(7, -1, -1),
    ]
    preview_frames: list[Image.Image] = []
    for frame_index in sequence:
        background = Image.new("RGB", (FRAME_WIDTH, FRAME_HEIGHT), "#f5f0e7")
        frame = frames[frame_index]
        background.paste(frame, mask=frame.getchannel("A"))
        preview_frames.append(background)

    preview_frames[0].save(
        PREVIEW_DIR / "kiwi-natural-walk-preview.gif",
        save_all=True,
        append_images=preview_frames[1:],
        duration=100,
        loop=0,
        optimize=True,
    )


def main() -> None:
    frames = normalize_frames()
    write_preview(frames)
    print(
        f"Wrote {len(frames)} natural walk frames and "
        f"{PREVIEW_DIR / 'kiwi-natural-walk-preview.gif'}"
    )


if __name__ == "__main__":
    main()
