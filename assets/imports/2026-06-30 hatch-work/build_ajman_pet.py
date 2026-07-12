#!/usr/bin/env python3
"""Build Ajman, a Codex-compatible animated pet atlas."""

from __future__ import annotations

import json
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageEnhance


RUN_DIR = Path("/Users/kazys/Documents/Codex/2026-06-30/hi/work/hatch-pet/ajman")
OUTPUTS_DIR = Path("/Users/kazys/Documents/Codex/2026-06-30/hi/outputs")
SKILL_DIR = Path("/Users/kazys/.codex/vendor_imports/skills/skills/.curated/hatch-pet")
PYTHON = Path("/Users/kazys/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3")

CELL_W = 192
CELL_H = 208
BASE_MAX_W = 152
BASE_MAX_H = 184

ROWS = {
    "idle": 6,
    "running-right": 8,
    "running-left": 8,
    "waving": 4,
    "jumping": 5,
    "failed": 8,
    "waiting": 6,
    "running": 6,
    "review": 6,
}


def clear_transparent_rgb(image: Image.Image) -> Image.Image:
    rgba = image.convert("RGBA")
    data = bytearray(rgba.tobytes())
    for index in range(0, len(data), 4):
        if data[index + 3] == 0:
            data[index] = 0
            data[index + 1] = 0
            data[index + 2] = 0
    return Image.frombytes("RGBA", rgba.size, bytes(data))


def load_sprite(filename: str) -> Image.Image:
    image = Image.open(RUN_DIR / "decoded" / filename).convert("RGBA")
    alpha = image.getchannel("A")
    bbox = alpha.point(lambda p: 255 if p > 8 else 0).getbbox()
    if bbox is None:
        raise SystemExit(f"{filename} has no visible pixels")

    cropped = image.crop(bbox)
    cropped.thumbnail((BASE_MAX_W, BASE_MAX_H), Image.Resampling.LANCZOS)
    return clear_transparent_rgb(cropped)


BASE = load_sprite("base.png")
RAISED = load_sprite("raised-paw.png")
RAISED_BODY_DX = 9


def make_sprite_frame(
    source: Image.Image,
    *,
    dx: float = 0,
    dy: float = 0,
    scale_x: float = 1.0,
    scale_y: float = 1.0,
    rotate: float = 0,
    darken: float = 1.0,
) -> tuple[Image.Image, tuple[int, int, int, int]]:
    width = max(1, round(source.width * scale_x))
    height = max(1, round(source.height * scale_y))
    sprite = source.resize((width, height), Image.Resampling.LANCZOS)
    if darken != 1.0:
        rgb = ImageEnhance.Brightness(sprite.convert("RGB")).enhance(darken)
        sprite = Image.merge("RGBA", (*rgb.split(), sprite.getchannel("A")))
    if rotate:
        sprite = sprite.rotate(rotate, expand=True, resample=Image.Resampling.BICUBIC)

    cell = Image.new("RGBA", (CELL_W, CELL_H), (0, 0, 0, 0))
    center_x = CELL_W / 2 + dx
    baseline = CELL_H - 8 + dy
    left = round(center_x - sprite.width / 2)
    top = round(baseline - sprite.height)
    cell.alpha_composite(sprite, (left, top))
    placed = (left, top, left + sprite.width, top + sprite.height)
    return clear_transparent_rgb(cell), placed


def make_frame(**kwargs) -> tuple[Image.Image, tuple[int, int, int, int]]:
    return make_sprite_frame(BASE, **kwargs)


def make_raised_frame(**kwargs) -> tuple[Image.Image, tuple[int, int, int, int]]:
    kwargs["dx"] = kwargs.get("dx", 0) + RAISED_BODY_DX
    return make_sprite_frame(RAISED, **kwargs)


def eye_points(placed: tuple[int, int, int, int]) -> list[tuple[float, float]]:
    left, top, right, bottom = placed
    width = right - left
    height = bottom - top
    return [
        (left + width * 0.39, top + height * 0.285),
        (left + width * 0.62, top + height * 0.285),
    ]


def draw_blink(frame: Image.Image, placed: tuple[int, int, int, int], strength: float = 1.0) -> None:
    draw = ImageDraw.Draw(frame, "RGBA")
    for x, y in eye_points(placed):
        w = 12 * strength
        h = 4 * strength
        draw.rounded_rectangle(
            (x - w, y - h, x + w, y + h),
            radius=max(1, round(h)),
            fill=(19, 19, 24, 235),
        )
        draw.line((x - w + 2, y, x + w - 2, y), fill=(0, 0, 0, 255), width=2)


def draw_squint(frame: Image.Image, placed: tuple[int, int, int, int]) -> None:
    draw = ImageDraw.Draw(frame, "RGBA")
    for x, y in eye_points(placed):
        draw.arc((x - 13, y - 9, x + 13, y + 9), 195, 345, fill=(0, 0, 0, 235), width=3)


def draw_wave_paw(frame: Image.Image, placed: tuple[int, int, int, int], lift: float) -> None:
    draw = ImageDraw.Draw(frame, "RGBA")
    left, top, right, bottom = placed
    px = right - 26 + 5 * lift
    py = top + 119 - 29 * lift
    draw.line((right - 41, top + 125, px - 4, py + 12), fill=(24, 24, 30, 230), width=7)
    draw.ellipse((px - 11, py - 10, px + 13, py + 12), fill=(250, 248, 244, 255), outline=(16, 16, 20, 245), width=2)
    for toe in (-5, 0, 5):
        draw.line((px + toe, py + 3, px + toe + 1, py + 10), fill=(92, 87, 91, 210), width=1)


def draw_small_paw(frame: Image.Image, placed: tuple[int, int, int, int], phase: float) -> None:
    draw = ImageDraw.Draw(frame, "RGBA")
    left, top, right, bottom = placed
    px = left + (right - left) * 0.64 + phase
    py = top + (bottom - top) * 0.66
    draw.ellipse((px - 9, py - 8, px + 10, py + 9), fill=(249, 247, 243, 250), outline=(20, 20, 24, 230), width=2)


def save_state(state: str, frames: list[Image.Image]) -> None:
    state_dir = RUN_DIR / "frames" / state
    state_dir.mkdir(parents=True, exist_ok=True)
    for index, frame in enumerate(frames):
        clear_transparent_rgb(frame).save(state_dir / f"{index:02d}.png")


def generate_frames() -> None:
    frames_root = RUN_DIR / "frames"
    if frames_root.exists():
        shutil.rmtree(frames_root)
    frames_root.mkdir(parents=True)

    idle_specs = [
        dict(scale_y=1.000, dy=0),
        dict(scale_y=1.012, dy=-1),
        dict(scale_y=1.004, dy=0),
        dict(scale_y=0.996, dy=1),
        dict(scale_y=1.010, dy=-1),
        dict(scale_y=1.000, dy=0),
    ]
    idle = []
    for index, spec in enumerate(idle_specs):
        frame, placed = make_frame(**spec)
        if index == 2:
            draw_blink(frame, placed)
        idle.append(frame)
    save_state("idle", idle)

    right = []
    for dx, dy, rot in [(-7, 0, -2), (-3, -1, 1), (2, 0, -1), (7, -2, 2), (9, 0, 1), (5, 1, -1), (0, 0, 1), (-4, -1, -1)]:
        frame, _placed = make_frame(dx=dx, dy=dy, rotate=rot)
        right.append(frame)
    save_state("running-right", right)

    left = []
    for dx, dy, rot in [(7, 0, 2), (3, -1, -1), (-2, 0, 1), (-7, -2, -2), (-9, 0, -1), (-5, 1, 1), (0, 0, -1), (4, -1, 1)]:
        frame, _placed = make_frame(dx=dx, dy=dy, rotate=rot)
        left.append(frame)
    save_state("running-left", left)

    wave = []
    for dx, dy, rot in [(-1, 0, -1), (1, -2, 1), (3, -1, 2), (0, 0, -1)]:
        frame, _placed = make_raised_frame(dx=dx, dy=dy, rotate=rot)
        wave.append(frame)
    save_state("waving", wave)

    jump = []
    for spec in [
        dict(scale_x=1.025, scale_y=0.975, dy=3),
        dict(scale_x=0.990, scale_y=1.015, dy=-9),
        dict(scale_x=1.000, scale_y=1.000, dy=-12),
        dict(scale_x=0.995, scale_y=1.010, dy=-12),
        dict(scale_x=1.020, scale_y=0.985, dy=1),
    ]:
        frame, _placed = make_frame(**spec)
        jump.append(frame)
    save_state("jumping", jump)

    failed = []
    for index, (dx, dy, rot) in enumerate([(0, 4, -2), (1, 5, -3), (0, 6, -2), (-1, 5, -1), (0, 6, 1), (1, 5, 2), (0, 5, 1), (0, 4, 0)]):
        frame, placed = make_frame(dx=dx, dy=dy, rotate=rot, scale_y=0.985, darken=0.90)
        draw_blink(frame, placed, strength=0.95)
        if index in (2, 5):
            draw = ImageDraw.Draw(frame, "RGBA")
            for x, y in eye_points(placed)[:1]:
                draw.ellipse((x - 2, y + 8, x + 3, y + 16), fill=(105, 165, 225, 220))
        failed.append(frame)
    save_state("failed", failed)

    waiting = []
    for dx, dy, rot in [(-1, 0, -1), (1, -2, 1), (3, -1, 2), (2, 0, 1), (0, -1, -1), (-1, 0, 0)]:
        frame, _placed = make_raised_frame(dx=dx, dy=dy, rotate=rot)
        waiting.append(frame)
    save_state("waiting", waiting)

    running = []
    for index, (dx, dy, rot) in enumerate([(-2, 0, 1), (0, -1, -1), (2, 0, 1), (1, -2, -1), (-1, 0, 1), (0, -1, 0)]):
        frame, placed = make_frame(dx=dx, dy=dy, rotate=rot)
        if index in (1, 3):
            draw_small_paw(frame, placed, phase=3 if index == 1 else -2)
        if index == 4:
            draw_squint(frame, placed)
        running.append(frame)
    save_state("running", running)

    review = []
    for index, (scale_y, dy, rot) in enumerate([(1.00, 0, 0), (1.012, -1, 1), (1.018, -2, 1), (1.010, -1, -1), (1.004, 0, 0), (1.00, 0, 0)]):
        frame, placed = make_frame(scale_y=scale_y, dy=dy, rotate=rot)
        if index in (0, 1, 2, 3, 4):
            draw_squint(frame, placed)
        review.append(frame)
    save_state("review", review)

    manifest = {
        "schema_version": 1,
        "chroma_key": {"hex": "#00FF00", "rgb": [0, 255, 0]},
        "rows": [
            {
                "state": state,
                "frames": count,
                "method": "components",
                "source": "deterministic animation from cleaned Ajman base sprite and raised-paw pose",
            }
            for state, count in ROWS.items()
        ],
    }
    (frames_root / "frames-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def run_checked(*args: str) -> None:
    subprocess.run([str(PYTHON), *args], check=True)


def package_outputs() -> None:
    package_dir = RUN_DIR / "package" / "ajman"
    package_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(RUN_DIR / "final/spritesheet.webp", package_dir / "spritesheet.webp")
    (package_dir / "pet.json").write_text(
        json.dumps(
            {
                "id": "ajman",
                "displayName": "Ajman",
                "description": "A calm tuxedo cat Codex pet with yellow-green eyes and white paws.",
                "spritesheetPath": "spritesheet.webp",
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )

    OUTPUTS_DIR.mkdir(parents=True, exist_ok=True)
    shutil.copy2(RUN_DIR / "final/spritesheet.webp", OUTPUTS_DIR / "ajman-spritesheet.webp")
    shutil.copy2(package_dir / "pet.json", OUTPUTS_DIR / "ajman-pet.json")
    shutil.copy2(RUN_DIR / "qa/contact-sheet.png", OUTPUTS_DIR / "ajman-contact-sheet.png")
    archive_base = OUTPUTS_DIR / "ajman-codex-pet"
    archive_path = shutil.make_archive(str(archive_base), "zip", root_dir=RUN_DIR / "package", base_dir="ajman")

    summary = {
        "ok": True,
        "package_dir": str(package_dir),
        "spritesheet": str(RUN_DIR / "final/spritesheet.webp"),
        "pet_json": str(package_dir / "pet.json"),
        "contact_sheet": str(RUN_DIR / "qa/contact-sheet.png"),
        "validation": str(RUN_DIR / "final/validation.json"),
        "review": str(RUN_DIR / "qa/review.json"),
        "previews": str(RUN_DIR / "qa/previews"),
        "outputs": {
            "spritesheet": str(OUTPUTS_DIR / "ajman-spritesheet.webp"),
            "pet_json": str(OUTPUTS_DIR / "ajman-pet.json"),
            "contact_sheet": str(OUTPUTS_DIR / "ajman-contact-sheet.png"),
            "zip": archive_path,
        },
    }
    (RUN_DIR / "qa/run-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    generate_frames()
    (RUN_DIR / "final").mkdir(parents=True, exist_ok=True)
    (RUN_DIR / "qa/previews").mkdir(parents=True, exist_ok=True)

    run_checked(
        str(SKILL_DIR / "scripts/inspect_frames.py"),
        "--frames-root",
        str(RUN_DIR / "frames"),
        "--json-out",
        str(RUN_DIR / "qa/review.json"),
        "--require-components",
    )
    run_checked(
        str(SKILL_DIR / "scripts/compose_atlas.py"),
        "--frames-root",
        str(RUN_DIR / "frames"),
        "--output",
        str(RUN_DIR / "final/spritesheet.png"),
        "--webp-output",
        str(RUN_DIR / "final/spritesheet.webp"),
    )
    run_checked(
        str(SKILL_DIR / "scripts/validate_atlas.py"),
        str(RUN_DIR / "final/spritesheet.webp"),
        "--json-out",
        str(RUN_DIR / "final/validation.json"),
    )
    run_checked(
        str(SKILL_DIR / "scripts/make_contact_sheet.py"),
        str(RUN_DIR / "final/spritesheet.webp"),
        "--output",
        str(RUN_DIR / "qa/contact-sheet.png"),
    )
    run_checked(
        str(SKILL_DIR / "scripts/render_animation_previews.py"),
        "--frames-root",
        str(RUN_DIR / "frames"),
        "--output-dir",
        str(RUN_DIR / "qa/previews"),
    )
    package_outputs()
    print(json.dumps(json.loads((RUN_DIR / "qa/run-summary.json").read_text()), indent=2))


if __name__ == "__main__":
    main()
