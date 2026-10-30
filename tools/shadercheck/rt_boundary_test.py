#!/usr/bin/env python3
"""Static RT/PT boundary checks for R6.

These are guardrails, not a substitute for runtime convergence tests. They
keep removed vanilla/SH/screen-AO transport from reappearing and verify that
contact AO, direct light, environment appearance, and emission stay separated.
"""
from __future__ import annotations

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
SHADERS = ROOT / "shaders"


def read(rel: str) -> str:
    return (SHADERS / rel).read_text(encoding="utf-8")


def main() -> int:
    failures: list[str] = []
    shader_files = [
        p for p in SHADERS.rglob("*")
        if p.suffix in {".glsl", ".fsh", ".vsh", ".csh", ".properties", ".lang"}
    ]
    forbidden = (
        "SH_SKYLIGHT", "VANILLA_AO", "DIRECTIONAL_LIGHTMAPS", "SHADER_AO",
        "SSAO_", "GTAO_", "AO_IN_SUNLIGHT", "RTGI_CONTACT_AO_STRENGTH",
        "compute_ssao", "compute_gtao", "compute_contact_ao",
        "VOXEL_VOLUME_SIZE", "VOXEL_VOLUME_CENTER",
    )
    for path in shader_files:
        text = path.read_text(encoding="utf-8", errors="replace")
        for token in forbidden:
            if token in text:
                failures.append(f"removed lighting token {token} in {path.relative_to(ROOT)}")

    for rel in (
        "include/lighting/ao/ssao.glsl", "include/lighting/ao/gtao.glsl",
        "include/lighting/directional_lightmaps.glsl",
        "include/utility/spherical_harmonics.glsl",
        "program/d4a_generate_sky_sh.csh", "world0/deferred4_a.csh",
    ):
        if (SHADERS / rel).exists():
            failures.append(f"removed legacy path still exists: {rel}")

    diffuse = read("include/lighting/diffuse_lighting.glsl")
    if diffuse.count("direct_lighting += material.emission * emission_scale;") != 1:
        failures.append("material emission must be added exactly once in diffuse composition")
    indirect = diffuse.split("// Indirect lighting: RT only.", 1)[-1].split(
        "direct_lighting += material.emission", 1
    )[0]
    if "sample_rtgi_smooth" not in indirect or "sample_ddgi_irradiance" not in indirect:
        failures.append("diffuse indirect must use filtered RTGI and forward probes")
    if re.search(r"\bao\b", indirect):
        failures.append("contact AO must not multiply traced indirect irradiance")
    if "ambient_color" in indirect or "sh_evaluate" in indirect:
        failures.append("analytic/SH ambient leaked into diffuse indirect")
    if "RT_AO_IN_DIRECT" not in diffuse or "diffuse *= sqr(ao);" not in diffuse:
        failures.append("configurable direct-light contact AO gate missing")
    if "light_color" not in diffuse or "SHADOW" not in diffuse:
        failures.append("intentional direct sun/moon or shadow-map path missing")

    ao_pass = read("program/d3_ao.fsh")
    if "compute_rt_ao" not in ao_pass or "voxel_sampler" not in ao_pass:
        failures.append("AO pass is not wired to voxel contact rays")
    if "RT_AO_STRENGTH <= 0.0" not in ao_pass or "is_hand" not in ao_pass:
        failures.append("AO neutral/disabled/hand guards missing")

    props = read("shaders.properties")
    for world in ("world0", "world-1", "world1"):
        if not re.search(rf"program\.{re.escape(world)}/deferred3\.enabled\s*=\s*true", props):
            failures.append(f"RT AO pass not enabled in {world}")
    if "deferred4_a" in props:
        failures.append("disabled sky-SH pass remains scheduled")
    for profile in ("low", "medium", "high", "ultra", "extreme"):
        line = next((l for l in props.splitlines() if l.startswith(f"profile.{profile} ")), "")
        if "RT_AO_RAYS=" not in line or "RT_AO_STRENGTH=" not in line:
            failures.append(f"profile {profile} lacks explicit RT AO budget")

    # Environment color is still legitimate for sky/fog/media appearance.
    for rel in ("program/d4_deferred_shading.vsh", "program/gbuffers_all_translucent.fsh"):
        if "texelFetch(colortex4, ivec2(191, 1), 0)" not in read(rel):
            failures.append(f"environment appearance sample missing in {rel}")

    if failures:
        for failure in failures:
            print("FAIL", failure)
        print(f"RT boundary: {len(failures)} failure(s)")
        return 1
    print("RT boundary test OK: RT contact AO, traced indirect, direct light, environment, emission")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
