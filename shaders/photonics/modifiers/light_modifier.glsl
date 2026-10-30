void modify_light(inout Light light, vec3 world_pos) {
    if (light.index < 0) {
#ifdef HANDHELD_LIGHTING_INTENSITY
        light.color *= HANDHELD_LIGHTING_INTENSITY;
#endif
    } else {
        light.color *= BLOCKLIGHT_I;
    }
}