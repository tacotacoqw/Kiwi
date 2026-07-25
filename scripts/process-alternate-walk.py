#!/usr/bin/env python3
"""Normalize the supplied 14-frame APNG into Kiwi's second walk style."""

from __future__ import annotations

from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter, ImageOps, ImageSequence


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Assets" / "Source" / "AlternateWalk" / "alternate-walk.png"
FRAMES_DIR = ROOT / "Assets" / "Frames"
PREVIEW_DIR = ROOT / "Assets" / "Preview"

FRAME_WIDTH = 420
FRAME_HEIGHT = 480
BASELINE = 464
TARGET_MAX_WIDTH = 300
TARGET_MAX_HEIGHT = 280
FRAME_COUNT = 14


def rough_character_bounds(image: Image.Image) -> tuple[int, int, int, int]:
    rgb = np.asarray(image.convert("RGB"))
    foreground = np.min(rgb, axis=2) < 248
    ys, xs = np.nonzero(foreground)
    if len(xs) == 0:
        raise ValueError("APNG frame does not contain a visible character")
    padding = 8
    return (
        max(0, int(xs.min()) - padding),
        max(0, int(ys.min()) - padding),
        min(image.width, int(xs.max()) + 1 + padding),
        min(image.height, int(ys.max()) + 1 + padding),
    )


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
        queue.append((0, x))
        queue.append((height - 1, x))
    for y in range(height):
        queue.append((y, 0))
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
    mask = mask.filter(ImageFilter.MinFilter(3))
    mask = mask.filter(ImageFilter.GaussianBlur(0.45))
    rgba = np.dstack((rgb, np.asarray(mask))).astype(np.uint8)
    result = Image.fromarray(rgba, mode="RGBA")
    bounds = result.getchannel("A").getbbox()
    if bounds is None:
        raise ValueError("Background removal erased the character")
    return result.crop(bounds)


def alpha_centroid_x(image: Image.Image) -> float:
    alpha = np.asarray(image.getchannel("A"), dtype=np.float64)
    total = alpha.sum()
    if total <= 0:
        return image.width / 2
    coordinates = np.arange(image.width, dtype=np.float64)
    return float((alpha.sum(axis=0) * coordinates).sum() / total)


def load_characters() -> list[Image.Image]:
    source = Image.open(SOURCE)
    frames = [
        frame.convert("RGBA").crop(rough_character_bounds(frame))
        for frame in ImageSequence.Iterator(source)
    ]
    if len(frames) != FRAME_COUNT:
        raise ValueError(
            f"Expected {FRAME_COUNT} APNG frames, found {len(frames)}"
        )
    return [remove_white_background(frame) for frame in frames]


def normalize_frames(characters: list[Image.Image]) -> list[Image.Image]:
    maximum_width = max(character.width for character in characters)
    maximum_height = max(character.height for character in characters)
    scale = min(
        TARGET_MAX_WIDTH / maximum_width,
        TARGET_MAX_HEIGHT / maximum_height,
    )

    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    normalized: list[Image.Image] = []
    for index, character in enumerate(characters, start=1):
        # The APNG was authored moving from right to left. Kiwi treats its
        # unmirrored asset as the right-facing baseline, so mirror every
        # source pose once while keeping the original chronological order.
        character = ImageOps.mirror(character)
        character = character.resize(
            (
                round(character.width * scale),
                round(character.height * scale),
            ),
            Image.Resampling.LANCZOS,
        )
        paste_x = round(FRAME_WIDTH / 2 - alpha_centroid_x(character))
        paste_y = BASELINE - character.height
        canvas = Image.new(
            "RGBA",
            (FRAME_WIDTH, FRAME_HEIGHT),
            (0, 0, 0, 0),
        )
        canvas.alpha_composite(character, (paste_x, paste_y))
        canvas.save(
            FRAMES_DIR / f"alternate-walk-{index:02d}.png",
            optimize=True,
        )
        normalized.append(canvas)
    return normalized


def write_preview(frames: list[Image.Image]) -> None:
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    sequence = [*range(FRAME_COUNT), *range(3, -1, -1)]
    preview_frames: list[Image.Image] = []
    travel = 260
    for sequence_index, frame_index in enumerate(sequence):
        if frame_index < 6:
            offset_x = 0 if sequence_index < FRAME_COUNT else travel
        else:
            offset_x = round((frame_index - 6) / 7 * travel)
        background = Image.new(
            "RGB",
            (FRAME_WIDTH + travel, FRAME_HEIGHT),
            "#f5f0e7",
        )
        frame = frames[frame_index]
        background.paste(
            frame,
            (offset_x, 0),
            mask=frame.getchannel("A"),
        )
        preview_frames.append(background)

    preview_frames[0].save(
        PREVIEW_DIR / "kiwi-alternate-walk-preview.gif",
        save_all=True,
        append_images=preview_frames[1:],
        duration=333,
        loop=0,
        optimize=True,
    )


def main() -> None:
    frames = normalize_frames(load_characters())
    write_preview(frames)
    print(
        f"Wrote {len(frames)} alternate walk frames and "
        f"{PREVIEW_DIR / 'kiwi-alternate-walk-preview.gif'}"
    )


if __name__ == "__main__":
    main()
