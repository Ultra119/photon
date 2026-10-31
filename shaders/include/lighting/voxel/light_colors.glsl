#if !defined INCLUDE_LIGHTING_VOXEL_LIGHT_COLORS
#define INCLUDE_LIGHTING_VOXEL_LIGHT_COLORS

const vec3[48] voxel_light_color_table = vec3[48](
    vec3(1.00, 1.00, 1.00) * 12.0, // Strong white light
    vec3(1.00, 1.00, 1.00) * 6.0, // Medium white light
    vec3(1.00, 1.00, 1.00) * 1.0, // Weak white light
    vec3(1.00, 0.55, 0.27) * 14.0, // Strong golden light
    vec3(1.00, 0.57, 0.30) * 8.0, // Medium golden light
    vec3(1.00, 0.57, 0.30) * 6.0, // Weak golden light
    vec3(1.00, 0.20, 0.08) * 1.5, // Redstone torch and lit redstone ore
    vec3(1.00, 0.38, 0.10) * 7.0, // Lava
    vec3(1.00, 0.45, 0.10) * 9.0, // Medium orange light
    vec3(1.00, 0.63, 0.15) * 4.0, // Brewing stand
    vec3(1.00, 0.57, 0.30) * 12.0, // Medium golden light
    vec3(0.45, 0.73, 1.00) * 6.0, // Soul lights
    vec3(0.45, 0.73, 1.00) * 14.0, // Beacon
    vec3(0.75, 1.00, 0.83) * 3.0, // Sculk
    vec3(0.75, 1.00, 0.83) * 1.0, // End portal frame
    vec3(0.60, 0.10, 1.00) * 2.5, // Pink glow
    vec3(0.75, 1.00, 0.50) * 1.0, // Sea pickle
    vec3(1.00, 0.50, 0.25) * 4.0, // Nether plants
    vec3(1.00, 0.57, 0.30) * 8.0, // Medium golden light
    vec3(1.00, 0.65, 0.30) * 8.0, // Ochre froglight
    vec3(0.86, 1.00, 0.44) * 8.0, // Verdant froglight
    vec3(0.75, 0.44, 1.00) * 8.0, // Pearlescent froglight
    vec3(0.60, 0.10, 1.00) * 2.0, // Enchanting table
    vec3(0.75, 0.44, 1.00) * 4.0, // Amethyst cluster
    vec3(0.75, 0.44, 1.00) * 4.0, // Calibrated sculk sensor
    vec3(0.75, 1.00, 0.83) * 6.0, // Active sculk sensor
    vec3(0.0), // Redstone components and logic (non-emitting)
    vec3(1.00, 0.50, 0.25) * 3.0, // Open eyeblossom
    vec3(0.85, 1.3, 1.0) * 3.9, // Copper torch and lanterns
    vec3(1.00, 0.57, 0.30) * 8.0, // Copper Bulbs
    vec3(0.60, 0.10, 1.00) * 12.0, // Nether portal
    vec3(0.0), // End portal
	// Colors for modded light sources (block IDs 64-79)
    vec3(1.00, 1.00, 1.00) * 10.0, // 32 - White       (block 64)
    vec3(0.85, 0.85, 0.85) *  9.0, // 33 - Light Gray  (block 65)
    vec3(0.55, 0.55, 0.55) *  8.0, // 34 - Gray        (block 66)
    vec3(0.20, 0.20, 0.22) *  6.0, // 35 - Black       (block 67)
    vec3(0.55, 0.35, 0.20) *  8.0, // 36 - Brown       (block 68)
    vec3(1.00, 0.10, 0.10) * 10.0, // 37 - Red         (block 69)
    vec3(1.00, 0.45, 0.10) * 10.0, // 38 - Orange      (block 70)
    vec3(1.00, 0.95, 0.20) * 10.0, // 39 - Yellow      (block 71)
    vec3(0.55, 1.00, 0.20) * 10.0, // 40 - Lime        (block 72)
    vec3(0.15, 1.00, 0.20) * 10.0, // 41 - Green       (block 73)
    vec3(0.15, 0.95, 1.00) * 10.0, // 42 - Cyan        (block 74)
    vec3(0.45, 0.75, 1.00) * 10.0, // 43 - Light Blue  (block 75)
    vec3(0.15, 0.30, 1.00) * 10.0, // 44 - Blue        (block 76)
    vec3(0.55, 0.15, 1.00) * 10.0, // 45 - Purple      (block 77)
    vec3(1.00, 0.20, 0.90) * 10.0, // 46 - Magenta     (block 78)
    vec3(1.00, 0.55, 0.85) * 10.0  // 47 - Pink        (block 79)
);

const vec3[16] voxel_tint_color_table = vec3[16](
    vec3(1.0, 0.1, 0.1), // Red
    vec3(1.0, 0.5, 0.1), // Orange
    vec3(1.0, 1.0, 0.1), // Yellow
    vec3(0.7, 0.7, 0.0), // Brown
    vec3(0.1, 1.0, 0.1), // Green
    vec3(0.5, 1.0, 0.5), // Lime
    vec3(0.1, 0.1, 1.0), // Blue
    vec3(0.5, 0.5, 1.0), // Light blue
    vec3(0.1, 1.0, 1.0), // Cyan
    vec3(0.7, 0.1, 1.0), // Purple
    vec3(1.0, 0.1, 1.0), // Magenta
    vec3(1.0, 0.5, 1.0), // Pink
    vec3(0.1, 0.1, 0.1), // Black
    vec3(0.9, 0.9, 0.9), // White
    vec3(0.3, 0.3, 0.3), // Gray
    vec3(0.7, 0.7, 0.7) // Light gray
);

// ---------------------------------------------------------------------------
// S4b — emission calibrated to actual Minecraft light levels.
//
// The color table above keeps its COLORS (peak-normalized where used); its
// artistic intensity multipliers are no longer a brightness source. Brightness
// comes from the entry's real light level through the vanilla lightmap
// response, so a light-15 emitter (glowstone, sea lantern, froglight...) is
// the reference emitter and a redstone torch (L1) is as faint as it is in
// vanilla, instead of the old palette*2.5 (glowstone at radiance 35, clipped
// by RTGI_MAX_RADIANCE=8 into a pure binary firefly).
//
// Index = block_id - 32, matching block.10032..block.10079 in
// block.properties. Entries marked (*) group decorative/non-emitting blocks
// alongside a real emitter or encode artistic intent; they keep a faint
// level instead of going fully dark.
// ---------------------------------------------------------------------------

const float[48] voxel_light_level_table = float[48](
     15.0, //  0 sea_lantern
     14.0, //  1 end_rod
      1.0, //  2 glow_lichen (*)
     15.0, //  3 glowstone, lantern, redstone_lamp:lit, creaking_heart:active
     14.0, //  4 torch, campfire:lit, furnace:lit, torchflower (torch-dominant)
     14.0, //  5 cave_vines:berries
      1.0, //  6 redstone_torch:lit, lit redstone ore
     15.0, //  7 lava
     15.0, //  8 fire, shroomlight (magma_block shares the entry; vanilla L3)
      1.0, //  9 brewing_stand
     15.0, // 10 jack_o_lantern
     10.0, // 11 soul_fire, soul_torch, soul_lantern, soul_campfire:lit
     15.0, // 12 beacon
      1.0, // 13 end_portal_frame:eye=true (*)
      1.0, // 14 sculk family, ominous trial spawner
     10.0, // 15 crying_obsidian (spawner/dragon head in the entry do not emit)
      6.0, // 16 sea_pickle:waterlogged (single pickle; 4 pickles reach 15)
      4.0, // 17 crimson/warped fungus (*)
     14.0, // 18 candle:lit (single candle)
     15.0, // 19 ochre_froglight
     15.0, // 20 verdant_froglight
     15.0, // 21 pearlescent_froglight
      1.0, // 22 enchanting_table
      5.0, // 23 amethyst cluster (buds share the entry; cluster is L5)
      1.0, // 24 calibrated_sculk_sensor inactive/cooldown
      1.0, // 25 sculk_sensor / calibrated_sculk_sensor active
      0.0, // 26 redstone components and logic (non-emitting)
      3.0, // 27 open_eyeblossom (*)
     14.0, // 28 copper_torch, copper_lantern
     15.0, // 29 copper_bulb:lit
     11.0, // 30 nether_portal
      0.0, // 31 end_portal / end_gateway (portal rendering handles the light)
     // Modded "illuminant" blocks (64-79): treated as full-bright lights.
     15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0,
     15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0
);

// Radiance of a light-15 emitter surface, times the user dial
// (EMISSION_STRENGTH, 0..2). Anchored to the raster block-light response
// (blocklight_scale = 6.0 at level 15), just under RTGI_MAX_RADIANCE (8) so
// legitimate emitter hits no longer saturate the per-ray firefly cap, and
// below the sunlight base scale (7.0 * SUN_I) so emitters stay believable
// next to daylight.
const float EMISSION_ANCHOR = 6.0;

// Vanilla lightmap response g(f) = f / (4 - 3f) (LightTexture curve):
// L15 -> 1.000, L14 -> 0.767, L11 -> 0.407, L10 -> 0.333, L6 -> 0.143,
// L5 -> 0.111, L3 -> 0.059, L1 -> 0.0175.
float voxel_light_response(float level) {
    float f = clamp(level, 0.0, 15.0) * (1.0 / 15.0);
    return f / max(4.0 - 3.0 * f, 1e-4);
}

#endif // INCLUDE_LIGHTING_VOXEL_LIGHT_COLORS
