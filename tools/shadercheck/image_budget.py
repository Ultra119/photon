#!/usr/bin/env python3
"""Per-profile custom-image (VRAM) budget for the PT quality tiers.

P0 renames the five surviving profiles to PT quality tiers, so "per mode"
allocation becomes "per tier" allocation: every tier allocates the same set of
images and only their dimensions change (RTGI resolution scale and clipmap
size). This script preprocesses `shaders.properties` the way Iris does, once
per profile, and reports what each tier actually allocates.

The numbers are nominal: bytes-per-texel assumes a tightly packed internal
format and no mipmaps, and relative images are evaluated at a reference render
resolution (1920x1080 by default) because their real size depends on the
window. Treat the output as a budget comparison between tiers, not as a driver
report.

Usage:
    python3 tools/shadercheck/image_budget.py            # markdown table
    IMAGE_BUDGET_WIDTH=2560 IMAGE_BUDGET_HEIGHT=1440 \
        python3 tools/shadercheck/image_budget.py
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from properties_lint import (  # noqa: E402
    IRIS_MAX_IMAGES,
    preprocess_properties,
    read_settings_defines,
    resolve_dimension,
)

# Nominal bytes per texel for the internal formats this pack declares.
BYTES_PER_TEXEL = {
    "R8": 1, "RG8": 2, "RGB8": 3, "RGBA8": 4,
    "R8_SNORM": 1, "RG8_SNORM": 2, "RGB8_SNORM": 3, "RGBA8_SNORM": 4,
    "R16": 2, "RG16": 4, "RGB16": 6, "RGBA16": 8,
    "R16_SNORM": 2, "RG16_SNORM": 4, "RGB16_SNORM": 6, "RGBA16_SNORM": 8,
    "R16F": 2, "RG16F": 4, "RGB16F": 6, "RGBA16F": 8,
    "R32F": 4, "RG32F": 8, "RGB32F": 12, "RGBA32F": 16,
    "R8I": 1, "RG8I": 2, "RGB8I": 3, "RGBA8I": 4,
    "R8UI": 1, "RG8UI": 2, "RGB8UI": 3, "RGBA8UI": 4,
    "R16I": 2, "RG16I": 4, "RGB16I": 6, "RGBA16I": 8,
    "R16UI": 2, "RG16UI": 4, "RGB16UI": 6, "RGBA16UI": 8,
    "R32I": 4, "RG32I": 8, "RGB32I": 12, "RGBA32I": 16,
    "R32UI": 4, "RG32UI": 8, "RGB32UI": 12, "RGBA32UI": 16,
    "RGBA2": 1, "RGBA4": 2, "R3_G3_B2": 1, "RGB5_A1": 2, "RGB565": 2,
    "RGB10_A2": 4, "RGB10_A2UI": 4, "R11F_G11F_B10F": 4, "RGB9_E5": 4,
}

MIB = 1024.0 * 1024.0


def parse_profile_tokens(tokens: list[str]) -> tuple[dict[str, str], set[str]]:
    """Split a profile line into `#define` overrides and `undef` set."""
    overrides: dict[str, str] = {}
    undef: set[str] = set()
    for token in tokens:
        if token.startswith("!"):
            undef.add(token[1:])
        elif "=" in token:
            name, value = token.split("=", 1)
            overrides[name] = value
        else:
            overrides[token] = "1"
    return overrides, undef


def read_profiles() -> list[tuple[str, list[str]]]:
    raw = (
        Path(os.environ.get("SHADER_ROOT", HERE.parents[1] / "shaders"))
        / "shaders.properties"
    ).read_text(encoding="utf-8", errors="replace")
    profiles: list[tuple[str, list[str]]] = []
    for line in raw.splitlines():
        stripped = line.strip()
        if not stripped.startswith("profile."):
            continue
        key, value = stripped.split("=", 1)
        tokens = value.split()
        # INFO=n drives the lang entry only; it does not gate an image.
        tokens = [t for t in tokens if not t.startswith("INFO=")]
        profiles.append((key.strip()[len("profile."):], tokens))
    return profiles


def active_images(
    preprocessed: str,
    settings: dict[str, str],
    width: int,
    height: int,
) -> tuple[list[tuple[str, int]], int]:
    """Return (name, bytes) pairs for every active image and the image count."""
    images: list[tuple[str, int]] = []
    for line in preprocessed.splitlines():
        text = line.strip()
        if not text.startswith("image.") or "=" not in text:
            continue
        name = text.split("=", 1)[0].strip()[len("image."):]
        fields = text.split("=", 1)[1].split()
        if len(fields) < 6:
            continue
        internal = fields[2].upper()
        pixel_bytes = BYTES_PER_TEXEL.get(internal)
        if pixel_bytes is None:
            raise SystemExit(f"unknown internal format '{internal}' for image.{name}")

        if fields[5] == "true":  # relative
            sx, sy = float(fields[6]), float(fields[7])
            texels = int(width * sx) * int(height * sy)
        else:
            texels = 1
            for dim in fields[6:]:
                resolved = resolve_dimension(dim, settings)
                if resolved is None:
                    raise SystemExit(
                        f"image.{name}: cannot resolve dimension '{dim}'"
                    )
                texels *= resolved
        images.append((name, texels * pixel_bytes))
    return images, len(images)


def mib(num_bytes: int) -> float:
    return num_bytes / MIB


def main() -> int:
    width = int(os.environ.get("IMAGE_BUDGET_WIDTH", "1920"))
    height = int(os.environ.get("IMAGE_BUDGET_HEIGHT", "1080"))
    settings = read_settings_defines()

    rows = []
    for name, tokens in read_profiles():
        overrides, undef = parse_profile_tokens(tokens)
        preprocessed = preprocess_properties(overrides, undef)
        defines = dict(settings)
        for key in undef:
            defines.pop(key, None)
        defines.update(overrides)
        images, count = active_images(preprocessed, defines, width, height)
        total = sum(size for _, size in images)
        scene = sum(size for n, size in images if n.startswith("voxel_"))
        chain = sum(size for n, size in images if n.startswith("rtgi_"))
        rows.append(
            {
                "profile": name,
                "rtgi": defines.get("RTGI_RESOLUTION", "1"),
                "clipmap": defines.get("RT_CLIPMAP_SIZE", "128"),
                "count": count,
                "scene": scene,
                "chain": chain,
                "total": total,
                "images": images,
            }
        )

    print(
        f"# Custom-image budget per PT quality tier "
        f"(reference render resolution {width}x{height})"
    )
    print()
    print(
        "Nominal bytes per texel, no mipmaps, relative images evaluated at the "
        "reference resolution above. Iris allows at most "
        f"{IRIS_MAX_IMAGES} custom images."
    )
    print()
    print("| PT quality tier | RTGI scale | Clipmap | Images | Voxel scene + cache | RTGI chain | Total |")
    print("|---|---|---|---:|---:|---:|---:|")
    for row in rows:
        print(
            f"| {row['profile']} | {row['rtgi']} | {row['clipmap']}³ | "
            f"{row['count']} | {mib(row['scene']):.2f} MiB | "
            f"{mib(row['chain']):.2f} MiB | {mib(row['total']):.2f} MiB |"
        )

    print()
    print("## Debug views")
    print()
    print(
        "The GI debug views allocate one extra `rgba8` image at the RTGI "
        "scale, so they are the worst case for the image count:"
    )
    print()
    print("| Tier | Extra debug image | Count with debug |")
    print("|---|---|---:|")
    for row in rows:
        extra = max((mib(size) for n, size in row["images"]
                     if n.startswith("rtgi_")), default=0.0) / 2.0
        print(
            f"| {row['profile']} | {extra:.2f} MiB (rgba8 at RTGI scale) | "
            f"{row['count'] + 1} |"
        )

    print()
    print("## Per-image detail (highest tier)")
    print()
    top = max(rows, key=lambda r: r["total"])
    print(f"| Image | Tier `{top['profile']}` |")
    print("|---|---:|")
    for name, size in sorted(top["images"], key=lambda kv: -kv[1]):
        print(f"| `{name}` | {mib(size):.2f} MiB |")
    print(f"| **Total** | **{mib(top['total']):.2f} MiB** |")

    over = [r for r in rows if r["count"] > IRIS_MAX_IMAGES]
    if over:
        print()
        for row in over:
            print(
                f"error: tier '{row['profile']}' declares {row['count']} images; "
                f"Iris allows {IRIS_MAX_IMAGES}"
            )
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
