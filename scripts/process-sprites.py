#!/usr/bin/env python3
"""Normalize the generated 4x2 transparent sprite sheet into animation frames."""

from pathlib import Path
from collections import deque

import numpy as np
from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Assets" / "Source" / "kiwi-idle-sprite.png"
WALK_SOURCE = ROOT / "Assets" / "Source" / "kiwi-walk-sprite.png"
FRAMES_DIR = ROOT / "Assets" / "Frames"
PREVIEW_DIR = ROOT / "Assets" / "Preview"

FRAME_WIDTH = 420
FRAME_HEIGHT = 360
BASELINE = 348


def active_runs(values: np.ndarray) -> list[tuple[int, int]]:
    runs: list[tuple[int, int]] = []
    start: int | None = None
    for index, active in enumerate(values):
        if active and start is None:
            start = index
        elif not active and start is not None:
            if index - start > 80:
                runs.append((start, index))
            start = None
    if start is not None and len(values) - start > 80:
        runs.append((start, len(values)))
    return runs


def main() -> None:
    sheet = Image.open(SOURCE).convert("RGBA")
    width, height = sheet.size
    if width % 4 or height % 2:
        raise ValueError(f"Expected a 4x2 sheet, got {width}x{height}")

    FRAMES_DIR.mkdir(parents=True, exist_ok=True)
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    normalized: list[Image.Image] = []

    alpha = np.asarray(sheet.getchannel("A"))
    row_height = height // 2
    column_width = width // 4

    for row in range(2):
        y0 = row * row_height
        y1 = y0 + row_height
        row_mask = alpha[y0:y1, :] > 32
        runs = active_runs(row_mask.sum(axis=0) > 3)
        if len(runs) != 4:
            raise ValueError(f"Expected four characters in row {row + 1}, found {runs}")

        for column, (x0, x1) in enumerate(runs):
            region_mask = row_mask[:, x0:x1]
            ys, xs = np.nonzero(region_mask)
            bounds = (
                x0 + int(xs.min()),
                y0 + int(ys.min()),
                x0 + int(xs.max()) + 1,
                y0 + int(ys.max()) + 1,
            )
            bird = sheet.crop(bounds)

            nominal_center_x = (column + 0.5) * column_width
            paste_x = round(FRAME_WIDTH / 2 + bounds[0] - nominal_center_x)
            paste_y = BASELINE - bird.height
            canvas = Image.new("RGBA", (FRAME_WIDTH, FRAME_HEIGHT), (0, 0, 0, 0))
            canvas.alpha_composite(bird, (paste_x, paste_y))

            frame_number = row * 4 + column + 1
            canvas.save(FRAMES_DIR / f"idle-{frame_number:02d}.png")
            normalized.append(canvas)

    # Use a single stable master drawing. Only the eye changes for the blink,
    # preventing the generated body outline from jittering between frames.
    idle_open = normalized[6].copy()
    idle_blink = make_eye_frame(idle_open, "blink")
    idle_open.save(FRAMES_DIR / "idle-open.png")
    idle_blink.save(FRAMES_DIR / "idle-blink.png")
    for pose in ("left", "right", "up", "half"):
        make_eye_frame(idle_open, pose).save(FRAMES_DIR / f"eye-{pose}.png")

    walk_frames = make_walk_frames()
    for index, frame in enumerate(walk_frames, start=1):
        frame.save(FRAMES_DIR / f"walk-{index:02d}.png")
        make_eye_frame(frame, "blink").save(FRAMES_DIR / f"walk-{index:02d}-blink.png")

    preview_frames = make_motion_preview(idle_open, idle_blink)
    preview_frames[0].save(
        PREVIEW_DIR / "kiwi-idle-preview.gif",
        save_all=True,
        append_images=preview_frames[1:],
        duration=50,
        loop=0,
        optimize=True,
    )
    walk_preview = make_walk_preview(walk_frames)
    walk_preview[0].save(
        PREVIEW_DIR / "kiwi-walk-preview.gif",
        save_all=True,
        append_images=walk_preview[1:],
        duration=50,
        loop=0,
        optimize=True,
    )
    eye_preview = make_eye_preview(idle_open)
    eye_preview[0].save(
        PREVIEW_DIR / "kiwi-eyes-preview.gif",
        save_all=True,
        append_images=eye_preview[1:],
        duration=50,
        loop=0,
        optimize=True,
    )
    print(
        f"Wrote {len(normalized)} idle source frames, {len(walk_frames)} walk frames, "
        f"eye poses, and previews in {PREVIEW_DIR}"
    )


def find_eye(source: Image.Image) -> tuple[int, int, int, int]:
    image = np.asarray(source)
    roi_x0, roi_x1 = 180, 330
    roi_y0, roi_y1 = 88, 190
    roi = image[roi_y0:roi_y1, roi_x0:roi_x1]
    dark = (roi[:, :, :3].mean(axis=2) < 88) & (roi[:, :, 3] > 220)
    visited = np.zeros(dark.shape, dtype=bool)
    candidates: list[tuple[int, int, int, int, int]] = []

    for start_y, start_x in zip(*np.nonzero(dark)):
        if visited[start_y, start_x]:
            continue
        queue = deque([(int(start_y), int(start_x))])
        visited[start_y, start_x] = True
        points: list[tuple[int, int]] = []
        while queue:
            y, x = queue.popleft()
            points.append((y, x))
            for dy, dx in ((-1, 0), (1, 0), (0, -1), (0, 1)):
                ny, nx = y + dy, x + dx
                if (
                    0 <= ny < dark.shape[0]
                    and 0 <= nx < dark.shape[1]
                    and dark[ny, nx]
                    and not visited[ny, nx]
                ):
                    visited[ny, nx] = True
                    queue.append((ny, nx))

        ys = [point[0] for point in points]
        xs = [point[1] for point in points]
        width = max(xs) - min(xs) + 1
        height = max(ys) - min(ys) + 1
        area = len(points)
        if 70 <= area <= 500 and 8 <= width <= 30 and 8 <= height <= 30:
            candidates.append(
                (
                    area,
                    min(xs) + roi_x0,
                    min(ys) + roi_y0,
                    max(xs) + roi_x0 + 1,
                    max(ys) + roi_y0 + 1,
                )
            )

    if not candidates:
        raise ValueError("Could not locate Kiwi's eye")
    _, x0, y0, x1, y1 = max(candidates)
    return x0, y0, x1, y1


def make_eye_frame(source: Image.Image, pose: str) -> Image.Image:
    eye_box = find_eye(source)
    center_x = (eye_box[0] + eye_box[2]) / 2
    center_y = (eye_box[1] + eye_box[3]) / 2
    patch_box = (
        round(center_x - 18),
        round(center_y - 17),
        round(center_x + 19),
        round(center_y + 18),
    )
    scale = 4
    patch = source.crop(patch_box).resize(
        ((patch_box[2] - patch_box[0]) * scale, (patch_box[3] - patch_box[1]) * scale),
        Image.Resampling.LANCZOS,
    )
    draw = ImageDraw.Draw(patch)

    source_array = np.asarray(source)
    sample = source_array[
        max(0, eye_box[1] - 8) : min(source.height, eye_box[3] + 8),
        max(0, eye_box[0] - 8) : min(source.width, eye_box[2] + 8),
    ]
    sample_mask = (
        (sample[:, :, 3] > 220)
        & (sample[:, :, :3].mean(axis=2) > 92)
        & (sample[:, :, :3].mean(axis=2) < 190)
    )
    sampled_colors = sample[sample_mask][:, :3]
    body_rgb = tuple(
        int(value) for value in np.median(sampled_colors, axis=0)
    ) if len(sampled_colors) else (122, 97, 75)
    body_color = (*body_rgb, 255)
    dark_color = (57, 45, 35, 255)
    draw.ellipse((3 * scale, 2 * scale, 34 * scale, 33 * scale), fill=body_color)

    local_center_x = (center_x - patch_box[0]) * scale
    local_center_y = (center_y - patch_box[1]) * scale
    if pose == "blink":
        points: list[tuple[int, int]] = []
        for step in range(25):
            fraction = step / 24
            x = local_center_x + (fraction - 0.5) * 18 * scale
            y = local_center_y - 2 * scale + 4 * scale * (
                1 - ((fraction - 0.5) / 0.5) ** 2
            )
            points.append((round(x), round(y)))
        draw.line(points, fill=dark_color, width=4 * scale, joint="curve")
    else:
        offset_x = {"left": -4, "right": 4, "up": 0, "half": 0}.get(pose, 0)
        offset_y = {"left": 0, "right": 0, "up": -4, "half": 1}.get(pose, 0)
        radius_x = 8
        radius_y = 4 if pose == "half" else 8
        cx = local_center_x + offset_x * scale
        cy = local_center_y + offset_y * scale
        draw.ellipse(
            (
                round(cx - radius_x * scale),
                round(cy - radius_y * scale),
                round(cx + radius_x * scale),
                round(cy + radius_y * scale),
            ),
            fill=dark_color,
        )

    patch = patch.resize(
        (patch_box[2] - patch_box[0], patch_box[3] - patch_box[1]),
        Image.Resampling.LANCZOS,
    )
    result = source.copy()
    result.alpha_composite(patch, (patch_box[0], patch_box[1]))
    return result


def make_walk_frames() -> list[Image.Image]:
    sheet = Image.open(WALK_SOURCE).convert("RGBA")
    width, height = sheet.size
    row_height = height // 2
    column_width = width // 3
    alpha = np.asarray(sheet.getchannel("A"))
    row_mask = alpha[:row_height, :] > 32
    runs = active_runs(row_mask.sum(axis=0) > 3)
    if len(runs) != 3:
        raise ValueError(f"Expected three walk poses in the first row, found {runs}")

    frames: list[Image.Image] = []
    for column, (x0, x1) in enumerate(runs):
        region_mask = row_mask[:, x0:x1]
        ys, xs = np.nonzero(region_mask)
        bounds = (
            x0 + int(xs.min()),
            int(ys.min()),
            x0 + int(xs.max()) + 1,
            int(ys.max()) + 1,
        )
        bird = sheet.crop(bounds)
        bird = bird.resize(
            (round(bird.width * 0.86), round(bird.height * 0.86)),
            Image.Resampling.LANCZOS,
        )
        paste_x = round((FRAME_WIDTH - bird.width) / 2)
        paste_y = BASELINE - bird.height
        canvas = Image.new("RGBA", (FRAME_WIDTH, FRAME_HEIGHT), (0, 0, 0, 0))
        canvas.alpha_composite(bird, (paste_x, paste_y))
        frames.append(canvas)
    return frames


def make_walk_preview(walk_frames: list[Image.Image]) -> list[Image.Image]:
    frames: list[Image.Image] = []
    sequence = [0, 1, 2, 1]
    fps = 20
    duration = 2.4
    canvas_width = 700

    for index in range(round(duration * fps)):
        elapsed = index / fps
        progress = elapsed / duration
        eased = progress * progress * (3 - 2 * progress)
        frame_index = sequence[int(elapsed * 7) % len(sequence)]
        bird = walk_frames[frame_index]
        if abs(elapsed - 1.15) < 0.1:
            bird = make_eye_frame(bird, "blink")

        canvas = Image.new("RGB", (canvas_width, FRAME_HEIGHT), "#f5f0e7")
        x = round(10 + eased * (canvas_width - FRAME_WIDTH - 20))
        canvas.paste(bird, (x, 0), mask=bird.getchannel("A"))
        frames.append(canvas)
    return frames


def make_eye_preview(idle_open: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    fps = 20
    poses = ["left", "right", "up", "half", "blink"]
    pose_frames = {pose: make_eye_frame(idle_open, pose) for pose in poses}
    segment_duration = 0.75

    for pose in poses:
        target = pose_frames[pose]
        for index in range(round(segment_duration * fps)):
            progress = index / max(1, round(segment_duration * fps) - 1)
            amount = np.sin(progress * np.pi)
            blended = Image.blend(idle_open, target, float(amount))
            background = Image.new("RGB", idle_open.size, "#f5f0e7")
            background.paste(blended, mask=blended.getchannel("A"))
            frames.append(background)
    return frames


def make_motion_preview(idle_open: Image.Image, idle_blink: Image.Image) -> list[Image.Image]:
    frames: list[Image.Image] = []
    fps = 20
    duration = 6.4
    frame_count = round(duration * fps)

    for index in range(frame_count):
        elapsed = index / fps
        phase = elapsed * (2 * np.pi / 4.2)
        breath = (1 - np.cos(phase)) * 0.5
        sway = np.sin(elapsed * (2 * np.pi / 6.4))
        blink_distance = abs(elapsed - 2.75)
        blink_amount = max(0.0, 1.0 - blink_distance / 0.11)

        blended = Image.blend(idle_open, idle_blink, blink_amount)
        scale_x = 1 - breath * 0.006
        scale_y = 1 + breath * 0.013
        offset_x = sway * 0.7
        offset_y = -breath * 1.5
        rotation = sway * 0.55

        if 0.9 <= elapsed < 1.8:
            progress = (elapsed - 0.9) / 0.9
            envelope = np.sin(progress * np.pi)
            wiggle = np.sin(progress * np.pi * 6) * envelope
            offset_x += wiggle * 2.2
            rotation += wiggle * 3.2
            scale_x += abs(wiggle) * 0.009
            scale_y -= abs(wiggle) * 0.006
        elif 2.45 <= elapsed < 3.5:
            progress = (elapsed - 2.45) / 1.05
            envelope = np.sin(progress * np.pi)
            hops = abs(np.sin(progress * np.pi * 2.15))
            squash = np.sin(progress * np.pi * 4.3) * envelope
            offset_y -= hops * envelope * 9
            scale_x += squash * 0.018
            scale_y -= squash * 0.013
            rotation += np.sin(progress * np.pi * 2) * envelope * 0.8
        elif 4.2 <= elapsed < 5.45:
            progress = (elapsed - 4.2) / 1.25
            eased = np.sin(progress * np.pi)
            offset_x += eased * 7
            offset_y -= eased * 2
            rotation -= eased * 2.8
            scale_y += eased * 0.009

        resized = blended.resize(
            (round(FRAME_WIDTH * scale_x), round(FRAME_HEIGHT * scale_y)),
            Image.Resampling.LANCZOS,
        )

        layer = Image.new("RGBA", idle_open.size, (0, 0, 0, 0))
        paste_x = round((FRAME_WIDTH - resized.width) / 2 + offset_x)
        paste_y = round(BASELINE - BASELINE * scale_y + offset_y)
        layer.alpha_composite(resized, (paste_x, paste_y))
        layer = layer.rotate(
            float(rotation),
            resample=Image.Resampling.BICUBIC,
            center=(FRAME_WIDTH / 2, BASELINE),
        )

        background = Image.new("RGB", idle_open.size, "#f5f0e7")
        background.paste(layer, mask=layer.getchannel("A"))
        frames.append(background)

    return frames


if __name__ == "__main__":
    main()
