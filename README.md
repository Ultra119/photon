<br><br>

<h1 align = "center">Photon Shaders</h1>

<p align = "center">A gameplay-focused shader pack for Minecraft</p>

![Screenshot](docs/images/rainbow.png)

## Acknowledgments

* Menu translations: 
  * [NakiriRuri](https://github.com/NakiriRuri) and [OrzMiku](https://github.com/Orzmiku) - Chinese Simplified (China; Mandarin)
  * [ChunghwaMC](https://github.com/ChunghwaMC) - Chinese Traditional (Taiwan; Mandarin)
  * [Jmayk](https://github.com/Jmayk-dev) - Italian
  * [Timtaran](https://github.com/Timtaran) - Russian
  * [shihyeon](https://github.com/shihyeon) - Korean
  * [DVRKHz](https://github.com/DVRKHz) - Spanish
  * [Patatagod69](https://github.com/PatataNL) - Dutch
  * sincerity - Estonian
* [Emin](https://github.com/EminGT) - Shadow bias method from [Complementary Reimagined](https://www.complementary.dev/shaders/) (fully fixes peter panning and light leaking underground!)
* [DrDesten](https://github.com/DrDesten) - Depth tolerance calculation for SSR (helps to prevent false reflections)
* [Essentuan](https://github.com/Essentuan) - Photonics mod support
* [Jessie](https://github.com/Jessie-LC) - f0 and f82 values for labPBR hardcoded metals
* [Sledgehammer Games](https://www.sledgehammergames.com/) - Bloom downsampling method used in Call of Duty Advanced Warfare (described [here](http://www.iryoku.com/next-generation-post-processing-in-call-of-duty-advanced-warfare))
* http://momentsingrapics.de/ - Blue noise texture
* [NASA Scientific Visualization Studio](https://svs.gsfc.nasa.gov/4851) - Galaxy image

## Installation

* This RTGI fork requires [Iris](https://irisshaders.dev/download) with compute shader and custom image support
* OptiFine is not supported by this fork because the RTGI pipeline uses Iris compute shaders, custom images, and custom uniforms
* Once Iris is installed, place the downloaded zip file in your `.minecraft/shaderpacks` folder

### Downloads
* [Releases](https://modrinth.com/shader/photon-shader/versions) (recommended)
* [Lastest commit](https://github.com/sixthsurge/photon/archive/refs/heads/main.zip)

## Features
* Fully revamped sky, lighting and water 
* Detailed clouds with many layers and cloud types
* Immersive weather system providing different skies each day
* Hybrid screen-space + voxel ray-traced global illumination (RTGI)
* Optional voxel-traced specular reflection fallback on supported profiles
* Screen-space reflections
* Volumetric fog
* Soft shadows with variable-size penumbras
* RTGI-based indirect lighting (dedicated contact AO is not implemented yet)
* Camera effects: bloom, depth of field, motion blur
* Much improved image quality with TAA, FXAA and CAS
* Advanced temporal upscaling (disabled by default) for low end devices
* Extensive settings menu allowing you to customize every aspect of the shader
* Full labPBR resource pack support

## Compatibility
### GPU vendors
* Nvidia 
* AMD 
* Intel 
* **_NOT_** Apple Metal
  * Compute shaders and custom images are required by this fork.
### Shader loaders
* Modern Iris with `COMPUTE_SHADERS` and `CUSTOM_IMAGES` support
* OptiFine is not supported
### Special mod support
* [Distant Horizons](https://www.curseforge.com/minecraft/mc-mods/distant-horizons)
* [Voxy](https://modrinth.com/mod/voxy)

## Showcase videos

<div align = "center">
	<a href="http://www.youtube.com/watch?feature=player_embedded&v=vxE_CVeU8Rs" target="_blank"><img src="http://img.youtube.com/vi/vxE_CVeU8Rs/0.jpg" border="0"/></a>
	<p> by iambeen
	<br><br>
</div>

<div align = "center">
	<a href="http://www.youtube.com/watch?feature=player_embedded&v=gMLFZMBK-ZQ" target="_blank"><img src="http://img.youtube.com/vi/gMLFZMBK-ZQ/0.jpg" border="0"/></a>
	<p> by CosmicNexus
	<br><br>
</div>

<div align = "center">
	<a href="http://www.youtube.com/watch?feature=player_embedded&v=_aSmM7jg9Nw" target="_blank"><img src="http://img.youtube.com/vi/_aSmM7jg9Nw/0.jpg" border="0"/></a>
	<p> by VIPUL
	<br><br>
</div>

## Community

- For questions, suggestions and news regarding this shader pack, head to my [discord server](https://discord.gg/ngEW66HScd)
- You can also [give me money](https://ko-fi.com/sixthsurge) if you want to 
