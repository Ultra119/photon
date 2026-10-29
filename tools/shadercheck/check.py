#!/usr/bin/env python3
import re,sys,subprocess,pathlib,tempfile,os,shutil
HERE=pathlib.Path(__file__).resolve().parent

def find_default_root():
    bases=[HERE]+list(HERE.parents)
    for base in bases:
        for candidate in (base/'shaders', base/'photon'/'shaders'):
            if candidate.exists():
                return candidate
    return pathlib.Path('/home/user/photon/shaders')

def find_default_glslang():
    for base in [HERE]+list(HERE.parents):
        candidate=base/'glslang'/'build'/'StandAlone'/'glslang'
        if candidate.exists():
            return str(candidate)
    return 'glslang'

DEFAULT_ROOT=find_default_root()
ROOT=pathlib.Path(os.environ.get('SHADER_ROOT',str(DEFAULT_ROOT))).resolve()
GLSLANG=os.environ.get('GLSLANG') or shutil.which('glslang') or shutil.which('glslangValidator') or find_default_glslang()
PREAMBLE_DEFS = r'''
#define MC_VERSION 12111
#define IS_IRIS
#define IRIS_FEATURE_CUSTOM_IMAGES
#define MC_GL_VENDOR_NVIDIA
#define MC_HAND_DEPTH 0.5
#define MC_RENDER_QUALITY 1.0
#define MC_SHADOW_QUALITY 1.0
// Iris WorldRenderingPhase ordinals
#define MC_RENDER_STAGE_NONE 0
#define MC_RENDER_STAGE_SKY 1
#define MC_RENDER_STAGE_SUNSET 2
#define MC_RENDER_STAGE_CUSTOM_SKY 3
#define MC_RENDER_STAGE_SUN 4
#define MC_RENDER_STAGE_MOON 5
#define MC_RENDER_STAGE_STARS 6
#define MC_RENDER_STAGE_VOID 7
#define MC_RENDER_STAGE_TERRAIN_SOLID 8
#define MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED 9
#define MC_RENDER_STAGE_TERRAIN_CUTOUT 10
#define MC_RENDER_STAGE_ENTITIES 11
#define MC_RENDER_STAGE_BLOCK_ENTITIES 12
#define MC_RENDER_STAGE_DESTROY 13
#define MC_RENDER_STAGE_OUTLINE 14
#define MC_RENDER_STAGE_DEBUG 15
#define MC_RENDER_STAGE_HAND_SOLID 16
#define MC_RENDER_STAGE_TERRAIN_TRANSLUCENT 17
#define MC_RENDER_STAGE_TRIPWIRE 18
#define MC_RENDER_STAGE_PARTICLES 19
#define MC_RENDER_STAGE_CLOUDS 20
#define MC_RENDER_STAGE_RAIN_SNOW 21
#define MC_RENDER_STAGE_WORLD_BORDER 22
#define MC_RENDER_STAGE_HAND_TRANSLUCENT 23
#define IRIS_TAG_SUPPORT 2
#define IRIS_SEPARATE_ENTITY_DRAWS
struct VoxyFragmentParameters { vec4 sampledColour; vec2 tile; vec2 uv; uint face; uint modelId; vec2 lightMap; vec4 tinting; uint customId; };
void clrwl_computeFragment(inout vec4 a, inout vec4 b, out vec2 lmcoord, out float ao, out vec4 overlayColor) { lmcoord = vec2(0.0); ao = 1.0; overlayColor = vec4(0.0); }
'''

# Uniforms that Iris injects or that are built-in OptiFine/MC uniforms.
COMMON_UNIFORMS = {
 'view_res':'uniform vec2 view_res;',
 'view_pixel_size':'uniform vec2 view_pixel_size;',
 'taa_offset':'uniform vec2 taa_offset;',
 'near':'uniform float near;',
 'far':'uniform float far;',
 'cameraPosition':'uniform vec3 cameraPosition;',
 'previousCameraPosition':'uniform vec3 previousCameraPosition;',
 'light_dir':'uniform vec3 light_dir;',
 'sun_dir':'uniform vec3 sun_dir;',
 'moon_dir':'uniform vec3 moon_dir;',
 'view_up_dir':'uniform vec3 view_up_dir;',
 'frameCounter':'uniform int frameCounter;',
 'frameTimeCounter':'uniform float frameTimeCounter;',
 'worldTime':'uniform int worldTime;',
 'worldDay':'uniform int worldDay;',
 'sunAngle':'uniform float sunAngle;',
 'moonPhase':'uniform int moonPhase;',
 'rainStrength':'uniform float rainStrength;',
 'wetness':'uniform float wetness;',
 'eye_skylight':'uniform float eye_skylight;',
 'eye_blocklight':'uniform float eye_blocklight;',
 'eyeAltitude':'uniform float eyeAltitude;',
 'isEyeInWater':'uniform int isEyeInWater;',
 'blindness':'uniform float blindness;',
 'nightVision':'uniform float nightVision;',
 'darknessFactor':'uniform float darknessFactor;',
 'aspectRatio':'uniform float aspectRatio;',
 'viewWidth':'uniform float viewWidth;',
 'viewHeight':'uniform float viewHeight;',
 'gbufferModelView':'uniform mat4 gbufferModelView;',
 'gbufferModelViewInverse':'uniform mat4 gbufferModelViewInverse;',
 'gbufferProjection':'uniform mat4 gbufferProjection;',
 'gbufferProjectionInverse':'uniform mat4 gbufferProjectionInverse;',
 'gbufferPreviousModelView':'uniform mat4 gbufferPreviousModelView;',
 'gbufferPreviousProjection':'uniform mat4 gbufferPreviousProjection;',
 'shadowModelView':'uniform mat4 shadowModelView;',
 'shadowModelViewInverse':'uniform mat4 shadowModelViewInverse;',
 'shadowProjection':'uniform mat4 shadowProjection;',
 'shadowProjectionInverse':'uniform mat4 shadowProjectionInverse;',
 'time_sunrise':'uniform float time_sunrise;',
 'time_noon':'uniform float time_noon;',
 'time_sunset':'uniform float time_sunset;',
 'time_midnight':'uniform float time_midnight;',
 'world_age':'uniform float world_age;',
 'biome_cave':'uniform float biome_cave;',
 'biome_may_rain':'uniform float biome_may_rain;',
 'biome_may_snow':'uniform float biome_may_snow;',
 'biome_snowy':'uniform float biome_snowy;',
 'biome_temperate':'uniform float biome_temperate;',
 'biome_arid':'uniform float biome_arid;',
 'biome_taiga':'uniform float biome_taiga;',
 'biome_jungle':'uniform float biome_jungle;',
 'biome_swamp':'uniform float biome_swamp;',
 'biome_temperature':'uniform float biome_temperature;',
 'biome_humidity':'uniform float biome_humidity;',
 'desert_sandstorm':'uniform float desert_sandstorm;',
 'biome_may_sandstorm':'uniform float biome_may_sandstorm;',
 'biome_pale_garden':'uniform float biome_pale_garden;',
 'moon_phase_brightness':'uniform float moon_phase_brightness;',
 'day_factor':'uniform float day_factor;',
 'atmosphere_saturation_boost_amount':'uniform float atmosphere_saturation_boost_amount;',
 'lightning_flash_iris':'uniform float lightning_flash_iris;',
 'lightning_flash_of':'uniform float lightning_flash_of;',
 'world_age_changed':'uniform bool world_age_changed;',
 'daylight_cycle_enabled':'uniform bool daylight_cycle_enabled;',
 'combined_near':'uniform float combined_near;',
 'combined_far':'uniform float combined_far;',
 'combined_projection_matrix_0':'uniform vec4 combined_projection_matrix_0;',
 'combined_projection_matrix_1':'uniform vec4 combined_projection_matrix_1;',
 'combined_projection_matrix_2':'uniform vec4 combined_projection_matrix_2;',
 'combined_projection_matrix_3':'uniform vec4 combined_projection_matrix_3;',
 'combined_projection_matrix_inverse_0':'uniform vec4 combined_projection_matrix_inverse_0;',
 'combined_projection_matrix_inverse_1':'uniform vec4 combined_projection_matrix_inverse_1;',
 'combined_projection_matrix_inverse_2':'uniform vec4 combined_projection_matrix_inverse_2;',
 'combined_projection_matrix_inverse_3':'uniform vec4 combined_projection_matrix_inverse_3;',
 'dhDepthTex':'uniform sampler2D dhDepthTex;',
 'dhDepthTex1':'uniform sampler2D dhDepthTex1;',
 'dhProjection':'uniform mat4 dhProjection;',
 'dhProjectionInverse':'uniform mat4 dhProjectionInverse;',
 'dhPreviousProjection':'uniform mat4 dhPreviousProjection;',
 'dhModelView':'uniform mat4 dhModelView;',
 'dhModelViewInverse':'uniform mat4 dhModelViewInverse;',
 'dhNearPlane':'uniform float dhNearPlane;',
 'dhFarPlane':'uniform float dhFarPlane;',
 'dhRenderDistance':'uniform int dhRenderDistance;',
 'vxDepthTexOpaque':'uniform sampler2D vxDepthTexOpaque;',
 'vxDepthTexTrans':'uniform sampler2D vxDepthTexTrans;',
 'vxProj':'uniform mat4 vxProj;',
 'vxProjInv':'uniform mat4 vxProjInv;',
 'vxProjPrev':'uniform mat4 vxProjPrev;',
 'vxRenderDistance':'uniform int vxRenderDistance;',
 'eyeBrightness':'uniform ivec2 eyeBrightness;',
 'sunPosition':'uniform vec3 sunPosition;',
 'moonPosition':'uniform vec3 moonPosition;',
 'upPosition':'uniform vec3 upPosition;',
 'skyColor':'uniform vec3 skyColor;',
 'fogColor':'uniform vec3 fogColor;',
 'biome':'uniform int biome;',
 'biome_category':'uniform int biome_category;',
 'biome_precipitation':'uniform int biome_precipitation;',
 'temperature':'uniform float temperature;',
 'rainfall':'uniform float rainfall;',
 'renderStage':'uniform int renderStage;',
 'entityColor':'uniform vec4 entityColor;',
 'at_midBlock':'in vec3 at_midBlock;',
 'at_tangent':'in vec4 at_tangent;',
 'mc_Entity':'in vec3 mc_Entity;',
 'mc_midTexCoord':'in vec2 mc_midTexCoord;',
 'gl_ModelViewMatrix':'uniform mat4 gl_ModelViewMatrix;',
 'gl_ProjectionMatrix':'uniform mat4 gl_ProjectionMatrix;',
 'gl_Vertex':'in vec4 gl_Vertex;',
 'gl_Normal':'in vec3 gl_Normal;',
 'gl_Color':'in vec4 gl_Color;',
 'gl_MultiTexCoord0':'in vec4 gl_MultiTexCoord0;',
 'gl_MultiTexCoord1':'in vec4 gl_MultiTexCoord1;',
 'gl_MultiTexCoord2':'in vec4 gl_MultiTexCoord2;',
 'gl_TextureMatrix':'uniform mat4 gl_TextureMatrix[8];',
 'tex':'uniform sampler2D tex;',
 'gtexture':'uniform sampler2D gtexture;',
 'lightmap':'uniform sampler2D lightmap;',
 'normals':'uniform sampler2D normals;',
 'specular':'uniform sampler2D specular;',
 'shadow':'uniform sampler2DShadow shadow;',
 'watershadow':'uniform sampler2DShadow watershadow;',
 'shadowtex0':'uniform sampler2D shadowtex0;',
 'shadowtex1':'uniform sampler2DShadow shadowtex1;',
 'shadowcolor0':'uniform sampler2D shadowcolor0;',
 'noisetex':'uniform sampler2D noisetex;',
 'depthtex0':'uniform sampler2D depthtex0;',
 'depthtex1':'uniform sampler2D depthtex1;',
 'depthtex2':'uniform sampler2D depthtex2;',
 'colortex0':'uniform sampler2D colortex0;',
 'colortex1':'uniform sampler2D colortex1;',
 'colortex2':'uniform sampler2D colortex2;',
 'colortex3':'uniform sampler2D colortex3;',
 'colortex4':'uniform sampler2D colortex4;',
 'colortex5':'uniform sampler2D colortex5;',
 'colortex6':'uniform sampler2D colortex6;',
 'colortex7':'uniform sampler2D colortex7;',
 'colortex8':'uniform sampler2D colortex8;',
 'colortex9':'uniform sampler2D colortex9;',
 'colortex10':'uniform sampler2D colortex10;',
 'colortex11':'uniform sampler2D colortex11;',
 'colortex12':'uniform sampler2D colortex12;',
 'colortex13':'uniform sampler2D colortex13;',
 'colortex14':'uniform sampler2D colortex14;',
 'colortex15':'uniform sampler2D colortex15;',
 'colortex16':'uniform sampler2D colortex16;',
 'colortex17':'uniform sampler2D colortex17;',
 'colortex18':'uniform sampler2D colortex18;',
 'voxel_sampler':'uniform usampler3D voxel_sampler;',
 'rtgi_raw_sampler':'uniform sampler2D rtgi_raw_sampler;',
 'rtgi_history_sampler':'uniform sampler2D rtgi_history_sampler;',
 'rtgi_accum_sampler':'uniform sampler2D rtgi_accum_sampler;',
 'rtgi_filtered_sampler':'uniform sampler2D rtgi_filtered_sampler;',
 'rtgi_sky_accum_sampler':'uniform sampler2D rtgi_sky_accum_sampler;',
 'rtgi_sky_history_sampler':'uniform sampler2D rtgi_sky_history_sampler;',
}

INC_RE=re.compile(r'^\s*#include\s+"([^"]+)"\s*$')

def resolve(path, stack=()):
    path=path.resolve()
    if path in stack:
        return '// include cycle: '+str(path)+'\n'
    out=[]
    out.append(f'// BEGIN {path.relative_to(ROOT.parent)}')
    for ln in path.read_text(errors='replace').splitlines():
        m=INC_RE.match(ln)
        if m:
            inc=m.group(1)
            if inc.startswith('/'):
                ip=(ROOT/inc.lstrip('/')).resolve()
            else:
                ip=(path.parent/inc).resolve()
            if ip.exists():
                out.append(resolve(ip, stack+(path,)))
            else:
                out.append('// MISSING INCLUDE '+inc)
        else:
            out.append(ln)
    out.append(f'// END {path.relative_to(ROOT.parent)}')
    return '\n'.join(out)+'\n'

def declared_names(src):
    names=set()
    # declarations like uniform sampler2D foo; or in/out vec3 foo;
    for m in re.finditer(r'^\s*(?:uniform|attribute|in|out|flat\s+in|flat\s+out|centroid\s+in|centroid\s+out)\b[^;{}]*?\b([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*;', src, re.M):
        names.add(m.group(1))
    # custom images
    for m in re.finditer(r'^\s*layout\s*\([^)]*\)\s*(?:writeonly\s+)?uniform\s+\w+\s+([A-Za-z_]\w*)\s*;',src,re.M):
        names.add(m.group(1))
    # const declarations
    for m in re.finditer(r'^\s*const\s+\w+\s+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*[=;]',src,re.M):
        names.add(m.group(1))
    return names

def parse_def(tok):
    # NAME=value, NAME (define as 1), !NAME (undef)
    if tok.startswith('!'):
        return tok[1:], None
    if '=' in tok:
        n,v=tok.split('=',1)
        return n, v
    return tok, '1'

def build(src_path, stage, defs=()):
    sp=str(src_path)
    path=(ROOT/sp.lstrip('/')).resolve() if sp.startswith('/') else (ROOT/sp).resolve()
    src=resolve(path)
    src=re.sub(r'^\s*#version\s+.*$','',src,count=1,flags=re.M)
    version='#version 430 compatibility\n' if stage=='vert' else '#version 430 core\n'
    pre=PREAMBLE_DEFS+'\n'
    overrides=[]
    for d in defs:
        if d.startswith('+'):
            pd=d[1:]
            n,v=parse_def(pd)
            pre += (f'#undef {n}\n' if v is None else f'#define {n} {v}\n')
            continue
        n,v=parse_def(d)
        if v is None:
            overrides.append(f'#undef {n}')
        else:
            overrides.append(f'#undef {n}\n#define {n} {v}')
    if overrides:
        marker='// END shaders/settings.glsl\n'
        if marker in src:
            src=src.replace(marker, marker+'\n'.join(overrides)+'\n',1)
        else:
            pre+='\n'.join(overrides)+'\n'
    declared=declared_names(src)
    unis=[]
    noinject=set(__import__('os').environ.get('NO_INJECT','').split(','))
    for name,decl in COMMON_UNIFORMS.items():
        if name in noinject: continue
        if name in declared: continue
        if stage!='vert' and (name.startswith('gl_') or decl.strip().startswith('in ')): continue
        if stage=='vert' and name.startswith('gl_'): continue
        unis.append(decl)
    full=version+pre+'\n'.join(unis)+'\n'+src
    return full

if __name__=='__main__':
    import os
    src=sys.argv[1]; stage=sys.argv[2]; defs=sys.argv[3:]
    full=build(src,stage,defs)
    tag=pathlib.Path(src).stem+'_'+(('_'.join(d.replace('=','-').replace('!','no') for d in defs)) or 'default')
    out=pathlib.Path('/tmp')/f'check_{tag}.{stage}'
    out.write_text(full)
    p=subprocess.run([GLSLANG,'-S',stage,str(out)],capture_output=True,text=True)
    print(p.stdout+p.stderr)
    print('source:',out,'lines:',len(full.splitlines()),'rc:',p.returncode)
