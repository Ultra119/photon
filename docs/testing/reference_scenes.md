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

## 4. Scene D: Vanilla Lightmap Non-Interference (No Double-Counting)

### Test Procedure
1. Dark enclosed room with 1 wall-mounted torch.
2. Toggle `RTGI_DIRECT_BLOCK_FALLBACK` between ON and OFF in `settings.glsl`.

### Acceptance Criteria
- When `RTGI_DIRECT_BLOCK_FALLBACK` is ON, direct receiver lighting comes cleanly from vanilla `mc_block` without secondary double-scaling.
- Solid non-emitter blocks in the voxel grid store zero lightmap bounce, guaranteeing that exterior roof torches do NOT leak light into interior spaces.

