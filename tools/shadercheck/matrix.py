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
'reflections_off':['RT_REFLECTION_RAYS=0'],
'reflections_2ray':['RT_REFLECTION_RAYS=2'],
'reflections_4ray':['RT_REFLECTION_RAYS=4'],
'normal_map':['NORMAL_MAPPING'],
'taau':['TAAU','TAAU_RENDER_SCALE=0.75'],
'taau_50':['TAAU','TAAU_RENDER_SCALE=0.50'],
'res0_8rays':['RTGI_RESOLUTION=0','RTGI_RAY_COUNT=8','RT_CLIPMAP_SIZE=128','RT_COVERAGE_LEVELS=3'],
'no_vl':['!VL'],
'no_shadow':['!SHADOW','!SHADOW_SSRT'],
'no_shadow_color':['!SHADOW_COLOR'],
'no_refraction':['REFRACTION=REFRACTION_OFF'],
'refraction_water':['REFRACTION=REFRACTION_WATER_ONLY'],
'rt_ao_off':['RT_AO_STRENGTH=0.00'],
'rt_ao_low':['RT_AO_STRENGTH=0.25','RT_AO_RAYS=2'],
'rt_ao_high':['RT_AO_STRENGTH=1.00','RT_AO_RAYS=8','RT_AO_RADIUS=2.00'],
'rt_ao_no_direct':['!RT_AO_IN_DIRECT'],
# GI debug views. GI_DEBUG_OFF must be the cheapest config, so it is
# covered alongside the views that allocate extra images.
'gi_debug_off':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_OFF'],
'gi_debug_raw':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_RAW'],
'gi_debug_hit':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_HIT'],
'gi_debug_reject':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_REJECT'],
'gi_debug_voxel':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_VOXEL_ID'],
'gi_debug_variance':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_VARIANCE'],
'clipmap_64':['RT_CLIPMAP_SIZE=64'],
'clipmap_96_levels2':['RT_CLIPMAP_SIZE=96','RT_COVERAGE_LEVELS=2'],
'clipmap_levels1':['RT_COVERAGE_LEVELS=1'],
'gi_debug_coverage':['DEBUG_VIEW=DEBUG_VIEW_GI','GI_DEBUG=GI_DEBUG_COVERAGE'],
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
