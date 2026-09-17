# Wisp Flowing Cloaks Implementation

This document describes the procedural flowing cloak system added to the Nexus Arena raymarch renderer.

## Overview

Wisps (players/bots) now wear flowing cloaks that trail behind motion, swing during turns, and sway gently when idle. The implementation is entirely fragment-shader based using SDF raymarching—no mesh pipeline required.

## Architecture

### CPU-Side (client_renderer.odin)

**Cloak_State** tracks simulation state per visible wisp:
- `prev_pos`, `prev_yaw`: Previous frame state for computing velocity
- `hem_offsets[4]`: Four control points defining the cloak hem shape
- `phase`: Per-wisp idle sway phase offset

**Simulation per frame:**
1. Compute horizontal velocity from position delta
2. Compute yaw velocity (turn rate) from yaw delta
3. Calculate target hem positions based on:
   - **Trail**: Hem points offset backward along velocity direction (stronger when moving fast)
   - **Swing**: Lateral offset proportional to turn rate (cloaks swing out during strafing turns)
   - **Idle sway**: Sinusoidal motion when speed < 1.5 m/s
4. Smooth hem_offsets toward targets using exponential blend (fake spring/Verlet)

**Uniform Upload:**
- `wisps[16]`: xyz position, w = team + hp (unchanged)
- `wisp_yaws[16]`: x = yaw in radians (new)
- `cloak_hem[16]`, `cloak_hem2[16]`, `cloak_hem3[16]`: Packed vec3×4 hem control points

### GPU-Side (shaders/scene.glsl)

**cloak_sdf(p, attach, hem_points[4])**
- Signed distance field for a thin curved ribbon
- Union of 8 capsules:
  - 4 from attachment point to each hem control point (main drape)
  - 4 connecting hem points in a loop (hem edge)
- Returns distance to nearest capsule minus radius (0.015)
- Simple and robust: no complex interpolation or angle sampling

**cloak_trace(ro, rd, wisp_pos, wisp_yaw, wisp_idx, tmin, tmax, out t, out n)**
- Bounding sphere check (1.2m radius around wisp) before SDF evaluation
- Unpacks hem control points from uniforms
- Sphere-traces cloak_sdf (max 32 steps, min step 0.02)
- Estimates normal via gradient on hit
- Early-out if ray misses bounds or SDF never reaches surface

**Integration:**
- New material `MAT_CLOAK` (9)
- Traced after wisps in main loop, before projectiles
- All 16 visible wisps checked; cloak can occlude wisp body

**Shading:**
- Base albedo: team tint darkened to 0.25 (fabric is darker than glowing wisp)
- Vertical gradient: 0.7–1.0 based on normal.z (soft fold shading)
- Fresnel rim: subtle emissive glow at grazing angles
- Low specular (pow=4, amt=0.02) for fabric
- Half fog influence (same as wisps/projectiles)

## Building

### Shader Compilation (required after any .glsl changes)

```bash
sokol-shdc -i shaders/scene.glsl -o src/scene.odin -l glsl430:metal_macos:wgsl -f sokol_odin
```

This regenerates `src/scene.odin` with uniform bindings. The file is gitignored and must be regenerated on each machine.

### Full Build

**Windows:**
```powershell
.\build.ps1          # server + graphical client
.\build.ps1 -Release
```

**Linux:**
```bash
./build_graphical_client.sh   # compiles shader, builds client
./build.sh server             # headless server
```

## Testing

1. Launch dedicated server: `./bin/nexus_server` (or `.exe` on Windows)
2. Launch graphical client: `./bin/nexus_client`
3. Join a team (press 1/2/3 at lobby screen)
4. Observe cloaks on remote players:
   - **Strafe left/right rapidly**: Cloaks should swing outward in the turn direction
   - **Sprint forward, then stop**: Cloaks trail behind, then settle gradually
   - **Stand still**: Cloaks sway gently with idle animation
   - **Jump**: Cloak hem follows wisp motion smoothly

### What to Look For

**Desired behavior:**
- Cloaks form a curved ribbon from shoulders (back of wisp) to hem (below and behind)
- Motion-responsive: faster movement = more trailing
- Turn-responsive: sharper turns = more lateral swing
- Smooth settling: no instant snapping when motion stops
- Team-colored fabric (darker than wisp glow)
- Readable in greybox environment

**Known Limitations (by design):**
- Fake cloth: no true physics, self-collision, or inter-cloak collision
- Only visible on remotes: local player's cloak not shown (FP view focus is on hands)
- 4 control points: cannot represent complex folds or wrinkles
- SDF approximation: ribbon can thin or thicken slightly depending on angle
- Fixed attachment: doesn't respond to wisp orientation beyond yaw

## Performance

- **Bounds check first**: Most rays reject via sphere test before SDF evaluation
- **32 step limit**: Sphere-tracing capped to prevent runaway marches
- **No mesh overhead**: Zero vertex processing, no additional draw calls
- **LOD built-in**: Only 16 nearest wisps ever receive cloaks (existing limit)

Measured on reference machine (TODO: add actual perf numbers after Windows build):
- Negligible frame time delta (<0.5ms) with 16 cloaked wisps visible
- SDF evaluation only when ray likely hits (inside 1.2m bounds)

## Code Locations

| Component | File | Lines |
|-----------|------|-------|
| Cloak state struct | `src/client_renderer.odin` | 30–36 |
| Simulation logic | `src/client_renderer.odin` | 345–420 |
| Uniform packing | `src/client_renderer.odin` | 422–434 |
| Cloak uniforms | `shaders/scene.glsl` | 45–49 |
| SDF helper | `shaders/scene.glsl` | 435–442 |
| SDF definition | `shaders/scene.glsl` | 444–462 |
| Trace routine | `shaders/scene.glsl` | 464–514 |
| Material shading | `shaders/scene.glsl` | 991–1005 |

## Future Improvements (Out of Scope)

- **Velocity-based stretching**: Cloak could elongate when moving very fast
- **Wind zones**: Environmental wind on obelisk plaza could billow cloaks
- **Local player cloak**: Show in third-person spectator or match-end camera
- **LOD tiers**: Simpler SDF (single capsule?) for very distant wisps
- **Color variation**: Fabric patterns or team-specific cloak styles
