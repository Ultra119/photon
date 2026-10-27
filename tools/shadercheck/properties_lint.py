#!/usr/bin/env python3
"""Lightweight shaders.properties / option consistency checks.

It uses `cpp` when available to resolve the subset of preprocessor directives
used by shaders.properties. Known upstream duplicate keys are reported but do
not fail the check; new duplicate keys do.
"""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = Path(os.environ.get("SHADER_ROOT", HERE.parents[2] / "photon" / "shaders")).resolve().parent
SHADERS = ROOT / "shaders"

KNOWN_DUPLICATE_KEYS = {
    "screen.blocklight_color.columns",
    "blend.gbuffers_armor_glint",
    "uniform.float.moon_phase_brightness",
}

RTGI_SCREEN_OPTIONS = [
    "RAYTRACED_GI",
    "RTGI_BRIGHTNESS",
    "RTGI_INTERIOR_RETENTION",
    "RTGI_CONTACT_AO_STRENGTH",
    "RTGI_POINT_LIGHT_STRENGTH",
    "RTGI_POINT_LIGHT_RADIUS",
    "RTGI_SSGI_LOCAL_LIGHT_SCALE",
    "RTGI_CAVE_AMBIENT_SCALE",
    "RTGI_RAY_COUNT",
    "RTGI_RESOLUTION",
    "RT_REFLECTIONS",
    "PHYSICAL_BSDF_ENERGY_COMP",
    "VOXEL_VOLUME_SIZE",
    "VOXEL_VOLUME_CENTER",
]

DEAD_OPTIONS = ["PHOTOMETRIC_EXPOSURE", "RT_AMBIENT_OCCLUSION"]

EXPECTED_CUSTOM_IMAGES = [
    "voxel_img",
    "rtgi_raw_img",
    "rtgi_history_img",
    "rtgi_accum_img",
    "rtgi_filtered_img",
    "rtgi_sky_accum_img",
    "rtgi_sky_history_img",
]

DIRECTIVE_WORDS = {
    "if", "ifdef", "ifndef", "elif", "else", "endif",
    "define", "undef", "include", "pragma", "error", "warning", "line",
}


def read_settings_defines() -> dict[str, str]:
    defs: dict[str, str] = {}
    for line in (SHADERS / "settings.glsl").read_text(encoding='utf-8', errors='replace').splitlines():
        m = re.match(r"^\s*#define\s+([A-Za-z_]\w*)\s+([^\s(/][^/]*?)\s*(?://.*)?$", line)
        if m:
            defs[m.group(1)] = m.group(2).strip()
            continue
        m = re.match(r"^\s*#define\s+([A-Za-z_]\w*)\s*$", line)
        if m:
            defs[m.group(1)] = "1"
    defs.setdefault("MC_VERSION", "12111")
    defs.setdefault("IRIS_TAG_SUPPORT", "2")
    defs.setdefault("MC_GL_VENDOR_NVIDIA", "1")
    return defs


def preprocess_properties() -> str:
    raw = (SHADERS / "shaders.properties").read_text(encoding='utf-8', errors='replace')
    defs = read_settings_defines()
    lines = [f"#define {k} {v}" for k, v in defs.items()]
    for line in raw.splitlines():
        stripped = line.lstrip()
        if stripped.startswith("#"):
            word = stripped[1:].split(None, 1)[0] if len(stripped) > 1 else ""
            if word not in DIRECTIVE_WORDS:
                lines.append("// " + line)
                continue
        lines.append(line)
    source = "\n".join(lines) + "\n"

    cpp = shutil.which("cpp")
    if cpp:
        with tempfile.NamedTemporaryFile("w", suffix=".c", delete=False) as f:
            f.write(source)
            tmp = Path(f.name)
        try:
            result = subprocess.run(
                [cpp, "-P", "-traditional-cpp", "-x", "c", str(tmp)],
                check=True, capture_output=True, text=True,
            )
            return result.stdout
        finally:
            tmp.unlink(missing_ok=True)

    # Fallback: keep all non-directive lines. Duplicate checks may be noisy.
    print("warning: cpp not found; using un-preprocessed properties", file=sys.stderr)
    return "\n".join(line for line in raw.splitlines() if not line.lstrip().startswith("#")) + "\n"


def property_keys(preprocessed: str) -> Counter:
    keys: Counter = Counter()
    for line in preprocessed.splitlines():
        text = line.strip()
        if not text or text.startswith("//") or "=" not in text:
            continue
        keys[text.split("=", 1)[0].strip()] += 1
    return keys


def main() -> int:
    if not SHADERS.exists():
        print(f"error: shader directory not found: {SHADERS}", file=sys.stderr)
        return 2

    preprocessed = preprocess_properties()
    keys = property_keys(preprocessed)
    duplicates = [(k, n) for k, n in keys.items() if n > 1]
    unexpected = [(k, n) for k, n in duplicates if k not in KNOWN_DUPLICATE_KEYS]

    # Parse the raw properties file for menu/slider tokens: cpp would expand
    # those macro names into their configured values.
    properties = (SHADERS / "shaders.properties").read_text(encoding='utf-8', errors='replace')
    screen_line = ""
    for line in properties.splitlines():
        if line.strip().startswith("screen.raytracing"):
            screen_line = line
            break

    lang = (SHADERS / "lang" / "en_US.lang").read_text(encoding='utf-8', errors='replace')
    settings = (SHADERS / "settings.glsl").read_text(encoding='utf-8', errors='replace')

    errors: list[str] = []
    warnings: list[str] = []

    for key, count in duplicates:
        if key in KNOWN_DUPLICATE_KEYS:
            warnings.append(f"known upstream duplicate key: {key} ({count})")
        else:
            errors.append(f"unexpected duplicate key: {key} ({count})")

    for opt in RTGI_SCREEN_OPTIONS:
        if opt not in screen_line:
            errors.append(f"missing from screen.raytracing: {opt}")
        if f"option.{opt}" not in lang:
            errors.append(f"missing en_US.lang option entry: {opt}")
        if f"#define {opt}" not in settings and f"// #define {opt}" not in settings:
            warnings.append(f"no settings.glsl define found for: {opt}")

    for opt in DEAD_OPTIONS:
        if opt in properties or opt in settings or opt in lang:
            errors.append(f"dead option still present: {opt}")

    for name in EXPECTED_CUSTOM_IMAGES:
        if f"image.{name}" not in properties:
            errors.append(f"missing custom image declaration: {name}")

    if "RAYTRACED_GI" not in screen_line:
        errors.append("RAYTRACED_GI is not exposed in the raytracing menu")

    for message in warnings:
        print("warning:", message)
    for message in errors:
        print("error:", message)

    if errors:
        print(f"properties lint failed: {len(errors)} error(s), {len(warnings)} warning(s)")
        return 1

    print(
        f"properties lint OK: {len(keys)} keys, "
        f"{len(duplicates)} known duplicate(s), "
        f"{len(RTGI_SCREEN_OPTIONS)} RTGI menu options checked"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
