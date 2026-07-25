#!/usr/bin/env python3
"""Normalize the five supplied Kiwi task-timer frames."""

from pathlib import Path
from shutil import copy2

from PIL import Image, ImageChops


ROOT = Path(__file__).resolve().parents[1]
SOURCE_DIR = ROOT / "Assets" / "Source" / "TaskTimer"
OUTPUT_DIR = ROOT / "Assets" / "Frames"
DOWNLOADS = Path.home() / "Downloads"
TARGET_HEIGHT = 720
PADDING = 20


def source_paths() -> list[Path]:
    SOURCE_DIR.mkdir(parents=True, exist_ok=True)
    paths: list[Path] = []
    for index in range(1, 6):
        stored = SOURCE_DIR / f"task-timer-{index:02d}-source.png"
        supplied = DOWNLOADS / f"未命名作品-{index}.png"
        if not stored.exists():
            if not supplied.exists():
                raise FileNotFoundError(
                    f"Missing supplied timer frame: {supplied}"
                )
            copy2(supplied, stored)
        paths.append(stored)
    return paths


def main() -> None:
    sources = source_paths()
    images = [Image.open(path).convert("RGBA") for path in sources]
    if len({image.size for image in images}) != 1:
        raise ValueError("Task timer frames must share one canvas size")

    union = Image.new("L", images[0].size, 0)
    for image in images:
        union = ImageChops.lighter(union, image.getchannel("A"))
    visible = union.getbbox()
    if visible is None:
        raise ValueError("Task timer frames contain no visible artwork")

    left, top, right, bottom = visible
    crop_box = (
        max(0, left - PADDING),
        max(0, top - PADDING),
        min(images[0].width, right + PADDING),
        min(images[0].height, bottom + PADDING),
    )
    cropped_width = crop_box[2] - crop_box[0]
    cropped_height = crop_box[3] - crop_box[1]
    scale = min(1.0, TARGET_HEIGHT / cropped_height)
    output_size = (
        round(cropped_width * scale),
        round(cropped_height * scale),
    )

    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for index, image in enumerate(images, start=1):
        result = image.crop(crop_box)
        if result.size != output_size:
            result = result.resize(output_size, Image.Resampling.LANCZOS)
        destination = OUTPUT_DIR / f"task-timer-{index:02d}.png"
        result.save(destination, optimize=True)
        print(f"{sources[index - 1].name} -> {destination.name} {result.size}")


if __name__ == "__main__":
    main()
