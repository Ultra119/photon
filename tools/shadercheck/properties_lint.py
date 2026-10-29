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

# Menu tokens that are not user options but submenu references or Iris
# directives. Anything else appearing in a screen.* line must resolve to a
# settings.glsl define that some shader actually reads.
NON_OPTION_TOKENS = {"<empty>", "<profile>", "screens", "subscreen", "columns"}

# Options that are legitimately consumed only by shaders.properties itself
# (program toggles, blend modes, per-pass enable flags) rather than by GLSL.
PROPERTIES_ONLY_OPTIONS = {
    "SHADOW",
    "VL",
    "TAAU",
    "TAA",
    "FXAA",
    "BLOOM",
    "DOF",
    "MOTION_BLUR",
    "DISTANT_HORIZONS",
    "VOXY",
    "COLORWHEEL",
    "WHITE_WORLD",
    "TONEMAP_COMPARISON",
    "tonemap_left",
    "tonemap_right",
    "DITHERED_TRANSLUCENCY_FALLBACK",
    "BOUNCE_GRID",
    "ENTITY_SHADOWS",
    "BLOCK_ENTITY_SHADOWS",
    "INFO",
}

# Menu options that were already dead upstream (defined, exposed in the menu,
# read by nothing). They are inherited debt, not fork regressions, so they are
# reported but do not fail the lint. Remove entries as Stage 10 cleans them up.
KNOWN_DEAD_OPTIONS = {
    "AURORA_GROUND_LIGHTING",
    "CLOUDS_CIRRUS_DETAIL_STRENGTH",
    "CLOUDS_CUMULUS_CONGESTUS_DENSITY",
    "CLOUDS_CUMULUS_CONGESTUS_WIND_SPEED",
    "CLOUDS_CUMULUS_CONGESTUS_WIND_ANGLE",
    "MOON_PHASE_AFFECTS_BRIGHTNESS",
}

# Menu tokens that reference no option at all: stale leftovers from upstream
# renames (e.g. WATER_REFRACTION became REFRACTION but the water submenu was
# never updated). They render as nothing in the menu. Inherited debt; fix them
# when touching those submenus rather than here.
KNOWN_MISSING_OPTIONS = {
    "CLOUDS_DAILY_WEATHER",
    "CLOUDS_CUMULUS_CONGESTUS_PRIMARY_STEPS_H",
    "CLOUDS_CUMULUS_CONGESTUS_PRIMARY_STEPS_Z",
    "WATER_REFRACTION",
    "WATER_REFRACTION_INTENSITY",
}

# Iris built-ins and const-declared options that live outside settings.glsl.
IMPLICIT_OPTIONS = {
    "shadowDistance",
    "shadowMapResolution",
    "sunPathRotation",
}


# --- Iris image directive validation ---------------------------------------
#
# Iris parses `image.<name> = ...` in ShaderProperties.java by splitting on a
# single space and reading fixed positions:
#
#   parts[0] sampler    parts[4] clear (boolean)
#   parts[1] PixelFormat          parts[5] relative (boolean)
#   parts[2] InternalTextureFormat
#   parts[3] PixelType            parts[6..] width/height[/depth]
#
# The field count is load-bearing: dropping the pixel type shifts every later
# field left, so Iris reads the clear flag as the pixel type and then tries to
# parse a float as an integer width, and the whole pack fails to load before a
# single shader is compiled. These name lists are taken from the Iris 26.3
# enums (PixelFormat, InternalTextureFormat, PixelType); fromString() is
# case-insensitive and matches the enum constant names exactly.

IMAGE_PIXEL_FORMATS = {
    "RED", "RG", "RGB", "BGR", "RGBA", "BGRA",
    "RED_INTEGER", "RG_INTEGER", "RGB_INTEGER", "BGR_INTEGER",
    "RGBA_INTEGER", "BGRA_INTEGER",
}

IMAGE_INTERNAL_FORMATS = {
    "RGBA", "R8", "RG8", "RGB8", "RGBA8",
    "R8_SNORM", "RG8_SNORM", "RGB8_SNORM", "RGBA8_SNORM",
    "R16", "RG16", "RGB16", "RGBA16",
    "R16_SNORM", "RG16_SNORM", "RGB16_SNORM", "RGBA16_SNORM",
    "R16F", "RG16F", "RGB16F", "RGBA16F",
    "R32F", "RG32F", "RGB32F", "RGBA32F",
    "R8I", "RG8I", "RGB8I", "RGBA8I",
    "R8UI", "RG8UI", "RGB8UI", "RGBA8UI",
    "R16I", "RG16I", "RGB16I", "RGBA16I",
    "R16UI", "RG16UI", "RGB16UI", "RGBA16UI",
    "R32I", "RG32I", "RGB32I", "RGBA32I",
    "R32UI", "RG32UI", "RGB32UI", "RGBA32UI",
    "RGBA2", "RGBA4", "R3_G3_B2", "RGB5_A1", "RGB565",
    "RGB10_A2", "RGB10_A2UI", "R11F_G11F_B10F", "RGB9_E5",
}

IMAGE_PIXEL_TYPES = {
    "BYTE", "SHORT", "INT", "HALF_FLOAT", "FLOAT",
    "UNSIGNED_BYTE", "UNSIGNED_BYTE_3_3_2", "UNSIGNED_BYTE_2_3_3_REV",
    "UNSIGNED_SHORT", "UNSIGNED_SHORT_5_6_5", "UNSIGNED_SHORT_5_6_5_REV",
    "UNSIGNED_SHORT_4_4_4_4", "UNSIGNED_SHORT_4_4_4_4_REV",
    "UNSIGNED_SHORT_5_5_5_1", "UNSIGNED_SHORT_1_5_5_5_REV",
    "UNSIGNED_INT", "UNSIGNED_INT_8_8_8_8", "UNSIGNED_INT_8_8_8_8_REV",
    "UNSIGNED_INT_10_10_10_2", "UNSIGNED_INT_2_10_10_10_REV",
    "UNSIGNED_INT_10F_11F_11F_REV", "UNSIGNED_INT_5_9_9_9_REV",
}

# Iris refuses to add a 17th image ("Only up to 16 images are allowed").
IRIS_MAX_IMAGES = 16


def check_image_directives(
    properties: str, preprocessed: str, settings: dict[str, str]
) -> tuple[list[str], list[str]]:
    """Validate every `image.*` line against Iris's parser.

    Syntax is checked on the *raw* file so that inactive #if branches are
    covered too -- a branch that does not load today still has to load for the
    user who selects it. The 16-image limit, by contrast, applies to the active
    set, so it is counted from the preprocessed output."""
    errors: list[str] = []
    warnings: list[str] = []
    count = 0

    for lineno, line in enumerate(properties.splitlines(), 1):
        stripped = line.strip()
        if not stripped.startswith("image.") or "=" not in stripped:
            continue
        count += 1
        key, value = stripped.split("=", 1)
        name = key.strip()[len("image."):]
        value = value.strip()

        # Iris splits on a single space, so a double space yields an empty
        # token that is read as the pixel format and silently becomes null.
        if "  " in value:
            errors.append(
                f"line {lineno}: image.{name} has a double space; Iris splits on "
                "single spaces and will read an empty field"
            )
        parts = value.split(" ")

        def bad(idx, label):
            got = parts[idx] if idx < len(parts) else "<missing>"
            errors.append(
                f"line {lineno}: image.{name} {label} '{got}' is not a valid "
                "Iris name"
            )

        if len(parts) < 6:
            errors.append(
                f"line {lineno}: image.{name} has {len(parts)} fields, "
                "at least 6 are required "
                "(sampler, format, internal format, pixel type, clear, relative)"
            )
            continue

        if parts[1].upper() not in IMAGE_PIXEL_FORMATS:
            bad(1, "pixel format")
        if parts[2].upper() not in IMAGE_INTERNAL_FORMATS:
            bad(2, "internal format")
        if parts[3].upper() not in IMAGE_PIXEL_TYPES:
            bad(3, "pixel type")

        for idx, label in ((4, "clear"), (5, "relative")):
            if parts[idx] not in ("true", "false"):
                warnings.append(
                    f"line {lineno}: image.{name} {label} flag is "
                    f"'{parts[idx]}'; Boolean.parseBoolean coerces this to false"
                )

        relative = parts[5] == "true"
        if relative:
            if len(parts) < 8:
                errors.append(
                    f"line {lineno}: image.{name} is relative but has "
                    f"{len(parts)} fields; width and height are required"
                )
                continue
            for idx in (6, 7):
                try:
                    float(parts[idx])
                except ValueError:
                    errors.append(
                        f"line {lineno}: image.{name} relative {idx - 5} "
                        f"dimension '{parts[idx]}' is not a number"
                    )
        else:
            if len(parts) not in (7, 8, 9):
                errors.append(
                    f"line {lineno}: image.{name} is absolute with "
                    f"{len(parts)} fields; Iris expects 7 (1D), 8 (2D) or 9 (3D)"
                )
                continue
            for idx in range(6, len(parts)):
                try:
                    int(parts[idx])
                except ValueError:
                    errors.append(
                        f"line {lineno}: image.{name} absolute dimension "
                        f"'{parts[idx]}' must be an integer"
                    )

    # An image written by an RTGI pass must be declared at the same relative
    # size as that pass's resolution, because those passes only write texels
    # below target_res. A larger image is sampled with most of it never
    # initialised; that is silent, not an error at load time.
    #
    # The debug images only exist when their GI_DEBUG value is selected, so the
    # default configuration would never show this. Re-evaluate the properties
    # once per CI-relevant GI_DEBUG value instead of trusting the default.
    rtgi_scale = {"0": "0.25", "1": "0.5", "2": "1.0"}
    for gd in ("GI_DEBUG_OFF", "GI_DEBUG_HIT", "GI_DEBUG_REJECT"):
        variant = preprocess_properties({"GI_DEBUG": gd})
        errors.extend(_rtgi_size_errors(variant, settings))
    active = sum(
        1
        for line in preprocessed.splitlines()
        if line.strip().startswith("image.") and "=" in line
    )
    if active > IRIS_MAX_IMAGES:
        errors.append(
            f"{active} image directives active at once; Iris refuses more than "
            f"{IRIS_MAX_IMAGES}"
        )
    return errors, warnings


def _rtgi_size_errors(preprocessed: str, settings: dict[str, str]) -> list[str]:
    errors: list[str] = []
    rtgi_scale = {"0": "0.25", "1": "0.5", "2": "1.0"}
    want = rtgi_scale.get(str(settings.get("RTGI_RESOLUTION", "1")), "0.5")
    for line in preprocessed.splitlines():
        text = line.strip()
        if not text.startswith("image.") or "=" not in text:
            continue
        name = text.split("=", 1)[0].strip()[len("image."):]
        if not name.startswith("rtgi_"):
            continue
        fields = text.split("=", 1)[1].split()
        if len(fields) < 8 or fields[5] != "true":
            continue
        if fields[6] != want or fields[7] != want:
            errors.append(
                f"image.{name} is {fields[6]}x{fields[7]} relative but the RTGI "
                f"pass writes at {want}x{want} "
                f"(RTGI_RESOLUTION={settings.get('RTGI_RESOLUTION', '1')}); "
                "the unwritten region would sample uninitialised memory"
            )
    return errors


def _menu_option_tokens(properties: str) -> set[str]:
    """Every option identifier referenced from a menu group or from sliders."""
    tokens: set[str] = set()
    for line in properties.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key = stripped.split("=", 1)[0].strip()
        if not (key.startswith("screen") or key == "sliders"):
            continue
        value = stripped.split("=", 1)[1]
        for raw in value.split():
            tok = raw.strip()
            if not tok or tok in NON_OPTION_TOKENS:
                continue
            if tok.startswith("[") and tok.endswith("]"):
                continue  # submenu reference
            if not re.fullmatch(r"[A-Za-z_]\w*", tok):
                continue
            tokens.add(tok)
    return tokens


def _shader_sources() -> list[tuple[Path, str]]:
    out: list[tuple[Path, str]] = []
    for pattern in ("*.glsl", "*.fsh", "*.vsh", "*.gsh", "*.csh", "*.inc"):
        for path in SHADERS.rglob(pattern):
            try:
                out.append((path, path.read_text(encoding="utf-8", errors="replace")))
            except OSError:
                continue
    return out


def check_orphan_options(properties: str, settings: str) -> tuple[list[str], list[str]]:
    """Find menu options that are defined but never read by any shader.

    A menu entry that changes nothing is worse than a missing feature: it looks
    supported and silently is not. This is the check that would have caught the
    PHOTOMETRIC_EXPOSURE / RT_AMBIENT_OCCLUSION dead options.
    """
    errors: list[str] = []
    warnings: list[str] = []
    tokens = _menu_option_tokens(properties)

    defined: set[str] = set(IMPLICIT_OPTIONS)
    for line in settings.splitlines():
        m = re.match(r"^\s*(?://\s*)?#define\s+([A-Za-z_]\w*)", line)
        if m:
            defined.add(m.group(1))
            continue
        # `const float shadowDistance = ...;` style options
        m = re.match(r"^\s*const\s+\w+\s+([A-Za-z_]\w*)\s*=", line)
        if m:
            defined.add(m.group(1))

    sources = _shader_sources()
    for tok in sorted(tokens):
        if tok in PROPERTIES_ONLY_OPTIONS:
            continue
        if tok not in defined:
            if tok in KNOWN_MISSING_OPTIONS:
                warnings.append(
                    f"known upstream stale menu token (references no option): {tok}"
                )
            else:
                errors.append(
                    f"menu token has no settings.glsl definition: {tok}"
                )
            continue

        uses = 0
        for path, text in sources:
            if path.name == "settings.glsl":
                continue
            for line in text.splitlines():
                if tok not in line:
                    continue
                if re.match(r"^\s*(?://\s*)?#define\s+" + re.escape(tok) + r"\b", line):
                    continue
                uses += 1
        if uses == 0:
            if tok in KNOWN_DEAD_OPTIONS:
                warnings.append(
                    f"known upstream dead option (menu entry does nothing): {tok}"
                )
            else:
                errors.append(
                    f"menu option defined but never read by any shader: {tok}"
                )

    return errors, warnings


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


def preprocess_properties(overrides: dict[str, str] | None = None) -> str:
    raw = (SHADERS / "shaders.properties").read_text(encoding='utf-8', errors='replace')
    defs = read_settings_defines()
    if overrides:
        defs.update(overrides)
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

    orphan_errors, orphan_warnings = check_orphan_options(properties, settings)
    errors.extend(orphan_errors)
    warnings.extend(orphan_warnings)

    image_errors, image_warnings = check_image_directives(
        properties, preprocessed, read_settings_defines()
    )
    errors.extend(image_errors)
    warnings.extend(image_warnings)

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
