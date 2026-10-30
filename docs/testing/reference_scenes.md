# RTGI Reference Scenes & Acceptance Benchmarks

This document specifies the standard test environments, physical ground truth equations, and numeric acceptance criteria for evaluating single-bounce (Stage 6) and multi-bounce (Stage 8) raytraced global illumination in Photon.

---

## 1. Scene A: The White Furnace (Energy Conservation & Radiosity)

### Geometry & Setup
- **Interior Dimensions**: $11 \times 11 \times 5$ blocks ($X \in [-5, 5]$, $Z \in [-5, 5]$, $Y \in [0, 4]$ interior clearance).
- **Enclosure Surfaces**: Fully sealed box built out of `minecraft:white_concrete`.
  - Nominal Albedo: $\rho = 1.00$ (pure diffuse white).
  - External light: Zero skylight ($light\_levels.y = 0$), no sunlight penetration.
- **Emitter**: Single centered block emitter at floor center $(0, 0, 0)$ or suspended at $(0, 2, 0)$.
  - Area of emitter surfaces: $A_e = 6.0\text{ m}^2$ (for an isolated 1-block cube) or $A_e = 5.0\text{ m}^2$ (floor-mounted cube with bottom occluded).
  - Emitted Radiance: $L_e$ (Lambertian radiant exitance).

### Radiometric Ground Truth Derivations
Total interior surface area of the $11 \times 11 \times 5$ room:
$$A_{\text{total}} = 2 \times (11 \times 11) + 4 \times (11 \times 5) = 242 + 220 = 462\text{ m}^2$$

1. **First-Bounce Incident Irradiance ($E_1$):**
   By flux conservation over the closed enclosure, the total radiant flux emitted is:
   $$\Phi_e = \pi \cdot L_e \cdot A_e$$
   Distributing this flux uniformly across the enclosure surfaces yields the spatial average single-bounce illuminance:
   $$E_1 = \frac{\Phi_e}{A_{\text{total}}} = \left(\frac{A_e}{A_{\text{total}}}\right) \cdot \pi L_e$$

2. **Infinite-Bounce Radiosity ($E_\infty$):**
   In a closed diffuse enclosure with uniform albedo $\rho$:
   $$E_\infty = \sum_{k=1}^\infty \rho^{k-1} E_1 = \frac{E_1}{1 - \rho} = \left(\frac{\rho}{1 - \rho}\right) \left(\frac{A_e}{A_{\text{total}}}\right) \pi L_e$$

### Numerical Acceptance Criteria (Stage 6)
- **Illuminance Tolerance:** The spatial mean indirect interior illuminance $\overline{E}_{\text{indirect}}$ measured across ceiling and wall receivers must be within **$\pm 10\%$** of $E_1$.
  - Upper failure threshold: $> 15\%$.
- **Chromatic Neutrality:** The measured interior chromaticity must not deviate from the emitter's chromaticity by more than $\Delta(u'v') < 0.005$. A white room illuminated by a neutral source must remain strictly neutral; channel-dependent drift indicates an erroneous color-space conversion or unbalanced albedo attenuation.

---

## 2. Scene B: Coloured Cabinet (Color Bleed & Spectrum Fidelity)

### Geometry & Setup
- **Interior Dimensions**: $7 \times 7 \times 4$ blocks (Cornell Box layout).
- **Surfaces**:
  - Floor & Ceiling: `minecraft:white_concrete` ($\rho_{\text{white}} \approx [0.85, 0.85, 0.85]$).
  - Left Wall ($X = -3$): `minecraft:red_concrete` ($\rho_{\text{red}} \approx [0.80, 0.10, 0.10]$).
  - Right Wall ($X = +3$): `minecraft:lime_concrete` or `light_blue_concrete`.
  - Back Wall ($Z = +3$): `minecraft:white_concrete`.
- **Illumination**: Direct sunlight enters at noon through a $2 \times 2$ ceiling opening directly onto the red wall ($N \cdot L > 0$).

### Radiometric Ground Truth
The indirect bounced radiance from the illuminated red wall onto adjacent white floor pixels is:
$$L_{o,\text{indirect}} = \rho_{\text{white}} \cdot \left(\frac{\rho_{\text{red}}}{\pi}\right) E_{\text{sun}}$$
The spectrum of the bounced light must exactly match $\rho_{\text{red}} \odot \text{spectrum}_{\text{sun}}$.

### Numerical Acceptance Criteria (Stage 6)
- **Color Bleeding Chromaticity:** Sampling a floor pixel $1.0\text{ m}$ from the red wall base must exhibit chromaticity matching $\rho_{\text{red}}$-tinted sunlight within $\Delta(u'v') < 0.010$.
- **No Desaturation / Bleed Leak:** The ceiling opposite the red wall should receive negligible direct red light compared to the floor, respecting cosine-weighted geometric form factors.

---

## 3. Scene C: Camera Independence & View Rotation

### Test Procedure
1. Position player in an interior room (e.g. Scene A or Scene B) at a fixed coordinate.
2. In Pure Voxel RT mode (`RTGI_TRACER = RTGI_TRACER_VOXEL`), rotate camera yaw smoothly through $360^\circ$ at $30^\circ/\text{sec}$.
3. Measure the luminance of a fixed world-space wall surface fragment across frames.

### Acceptance Criteria
- **Luminance Variance:** Temporal luminance variation on the fixed world surface during camera rotation must be **$< 2\%$**.
- **No Edge Popping:** No dark edges, bright flashes, or disocclusion seams appear as geometry enters or leaves the camera frustum.

---

## 4. Scene D: RT Direct/Indirect Boundary (No Double-Counting)

### Test Procedure
1. Dark enclosed room with one wall-mounted torch and a sunlit exterior wall.
2. Compare `RT_AO_STRENGTH = 0.00` and `0.50`, with `RT_AO_IN_DIRECT` on/off.
3. Inspect the torch-lit interior, the sunlit exterior, and a white wall beside a coloured wall.

### Acceptance Criteria
- Interior indirect light comes from voxel emitters/probes, not vanilla blocklight or SH ambient.
- Contact AO changes direct-light crevice detail only; it does not scale the traced indirect term.
- Toggling `RT_AO_IN_DIRECT` changes direct diffuse/specular contact detail without removing shadow-map visibility.
- Material emission is visible once; moving the emitter does not create a second analytic surface glow.

---

## 5. Scene E: RT Contact AO Coverage and Motion

### Test Procedure
1. Place slabs, stairs, fences, and a full cube against a wall; view corners at grazing angles.
2. Move the camera past the objects and rotate in place; repeat near the voxel-volume edge and with DH/Voxy terrain.
3. Test `RT_AO_RAYS = 2/4/8`, `RT_AO_RADIUS = 0.25/0.75/2.00`, and strength zero.

### Acceptance Criteria
- Strength zero and the hand are neutral; no stale AO history remains after disabling the effect.
- Uncovered/LOD surfaces do not fall back to vanilla AO, SSAO/GTAO, or analytic ambient.
- Contact darkening stays local, does not double-darken RTGI, and does not produce persistent edge trails during motion.
- Higher ray counts reduce noise; radius changes affect only short-range contact detail.

---

## 6. Scene F: Clipmap Coverage and Seams

### Test Procedure
1. Stand in open terrain with `RT_COVERAGE_LEVELS=3`, `RT_CLIPMAP_SIZE=128`; enable `GI_DEBUG_COVERAGE`.
2. Walk across fine→medium→coarse boundaries and rotate in place; repeat with `shadowDistance` 128/256.
3. Place an emitter behind the camera and near a level seam; compare GI/reflection brightness across the seam.
4. Repeat with `RT_COVERAGE_LEVELS=1/2` and with DH/Voxy enabled.

### Acceptance Criteria
- Coverage view shows bright red/green/blue for populated fine/medium/coarse voxels, dark hue for in-bounds cells with no voxel record, yellow boundary tint, and magenta only outside all active clipmaps. Medium/coarse rings must not be cut off by the fine-volume boundary.
- No stale voxel trails after camera motion; boundaries do not produce duplicate bright emitter bands.
- Emitter radiance and glass tint do not double at level transitions.
- With DH/Voxy, uncovered LOD terrain does not fall back to original Photon lighting; it uses RT/probe/environment transport or remains explicitly uncovered.
