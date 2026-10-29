#!/usr/bin/env python3
import subprocess, itertools, pathlib
CHECK=str(pathlib.Path(__file__).resolve().parent/'check.py')
FILES=[
'/world0/composite.fsh','/world0/composite1.fsh','/world0/composite3.fsh','/world0/deferred3.fsh','/world0/deferred4.fsh','/world0/final.fsh',
'/world0/gbuffers_terrain.fsh','/world0/gbuffers_terrain_solid.fsh','/world0/gbuffers_block.fsh','/world0/gbuffers_entities.fsh','/world0/gbuffers_hand.fsh','/world0/gbuffers_particles.fsh','/world0/gbuffers_spidereyes.fsh','/world0/gbuffers_beaconbeam.fsh',
'/world0/gbuffers_water.fsh','/world0/gbuffers_block_translucent.fsh','/world0/gbuffers_entities_translucent.fsh','/world0/gbuffers_hand_water.fsh','/world0/gbuffers_lightning.fsh','/world0/gbuffers_particles_translucent.fsh','/world0/gbuffers_textured.fsh',
'/world0/shadow.fsh','/world0/shadow_block.fsh','/world0/shadow_cutout.fsh','/world0/shadow_entities.fsh','/world0/shadow_solid.fsh','/world0/shadow_water.fsh',
'/world-1/deferred4.fsh','/world-1/gbuffers_water.fsh','/world-1/gbuffers_terrain_solid.fsh','/world-1/shadow.fsh','/world-1/composite1.fsh','/world-1/final.fsh',
'/world1/deferred4.fsh','/world1/gbuffers_water.fsh','/world1/gbuffers_terrain_solid.fsh','/world1/shadow.fsh','/world1/composite1.fsh','/world1/final.fsh',
]
VARIANTS={
'default':[],
'rtgi_off':['!RAYTRACED_GI'],
'rtgi_refl_off':['!RAYTRACED_GI','!RT_REFLECTIONS'],
'normal_map':['NORMAL_MAPPING'],
'taau':['TAAU','TAAU_RENDER_SCALE=0.75'],
'taau_50':['TAAU','TAAU_RENDER_SCALE=0.50'],
'res0_8rays':['RTGI_RESOLUTION=0','RTGI_RAY_COUNT=8','VOXEL_VOLUME_SIZE=512'],
'no_sh_skylight':['!SH_SKYLIGHT'],
'no_vl':['!VL'],
'no_shadow':['!SHADOW','!SHADOW_SSRT'],
'no_shadow_color':['!SHADOW_COLOR'],
'no_refraction':['REFRACTION=REFRACTION_OFF'],
'refraction_water':['REFRACTION=REFRACTION_WATER_ONLY'],
'no_env_refl':['!ENVIRONMENT_REFLECTIONS','!SKY_REFLECTIONS'],
'no_ssr_rough':['!SSR_ROUGHNESS_SUPPORT'],
'no_ao':['!SHADER_AO'],
# An undefined SHADER_AO reads as 0 in `#if`, which happens to equal
# SHADER_AO_NONE. Cover each mode explicitly so the intent is on record.
'ao_none':['SHADER_AO=SHADER_AO_NONE'],
'ao_ssao':['SHADER_AO=SHADER_AO_SSAO'],
'ao_gtao':['SHADER_AO=SHADER_AO_GTAO'],
'ao_contact':['SHADER_AO=SHADER_AO_CONTACT'],
'ao_gtao_rtgi_off':['SHADER_AO=SHADER_AO_GTAO','!RAYTRACED_GI'],
'ao_contact_rtgi_off':['SHADER_AO=SHADER_AO_CONTACT','!RAYTRACED_GI'],
'voxel_64':['VOXEL_VOLUME_SIZE=64'],
'voxel_256':['VOXEL_VOLUME_SIZE=256'],
'voxel_512':['VOXEL_VOLUME_SIZE=512'],
'voxel_ahead':['VOXEL_VOLUME_CENTER=VOXEL_VOLUME_CENTER_AHEAD'],
}
fail=[];total=0
for f,vn in itertools.product(FILES,VARIANTS):
    st='vert' if f.endswith('.vsh') else 'frag'
    defs=VARIANTS[vn]; total+=1
    p=subprocess.run(['python3',CHECK,f,st]+defs,capture_output=True,text=True)
    if p.returncode!=0 or 'ERROR' in p.stdout or 'ERROR' in p.stderr:
        fail.append((f,vn,defs,(p.stdout+p.stderr).strip()[:700]))
print('total',total,'fail',len(fail))
for f,vn,d,o in fail:
    print('\n---',f,vn,d,'---\n',o)
