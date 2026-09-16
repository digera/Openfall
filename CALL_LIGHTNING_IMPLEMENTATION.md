# Call Lightning Implementation

## Overview
Added **Call Lightning** as the 5th spell - a targeted, long-cast, high-damage lightning strike from the sky.

## Spell Characteristics
- **Cast Time**: 1.8 seconds (long channel)
- **Mana Cost**: 60 (heavy)
- **Cooldown**: 8.0 seconds
- **Max Range**: 22 meters
- **Damage**: 85 (direct hit)
- **AoE**: 2.5 meter radius, 40% splash damage
- **Hotbar Slot**: 5 (press `5` to select)

## Spell Behavior
1. **Target Acquisition**: Server finds the best enemy in the caster's crosshair cone (85° dot threshold)
2. **Cast Channel**: 1.8s cast time during which the target must remain valid
3. **Continuous Validation** (every tick + at cast end):
   - Target alive
   - In range (≤22m)
   - **Clear LOS** (caster eye → target center via `world_segment_clear`)
   - If any check fails → **spell fails and refunds mana + cooldown**
4. **Strike**: On successful completion, lightning bolt strikes from sky (45m above ground) to target
5. **Damage**: Direct hit on primary target + splash damage to nearby enemies

### LOS Policy (Anti-Corner-Shooting)
- **Horizontal LOS**: Gameplay collision check is caster→target (eye to center)
- **Sky bolt is VFX only**: Visual comes from above but doesn't bypass cover
- **Cannot wall-shoot**: Target ducking behind pillar during cast = fail + refund

## Technical Implementation

### Core Systems Modified

#### 1. Spell Definition (`src/spells.odin`)
- Added `Call_Lightning` to `Spell_ID` enum
- New `Lightning` payload type for targeted strikes
- Added `cast_time` field for channeled spells
- Extended `HOTBAR` to 5 slots
- Added `Lightning_Strike` VFX tracking system

#### 2. Entity Spell State (`src/spells.odin`)
```odin
Entity_Spell_State :: struct {
    cooldowns:       [Spell_ID]f32,
    casting:         bool,          // NEW: is channeling
    cast_spell:      Spell_ID,      // NEW: which spell
    cast_progress:   f32,           // NEW: elapsed time
    cast_target_id:  Entity_ID,     // NEW: for targeted spells
}
```

#### 3. Server Logic (`src/server.odin`)
- **`server_handle_spell_cast`**: Start cast or fire instant spell
  - For Lightning: finds best target via `server_find_best_target`
  - Consumes mana/cooldown upfront
  - Starts channel for cast-time spells
- **`server_update_resources`**: Advances cast progress each tick
  - **Continuous validation**: For Lightning, checks alive/range/**LOS** every tick
  - **Interrupts cast** if target becomes invalid → refunds mana/cooldown
- **`server_finish_cast`**: Final validation before strike
  - **Final LOS check**: `world_segment_clear(caster_eye, target_center)` before damage
  - Refunds mana/cooldown if target lost or **LOS broken**
- **`server_lightning_strike`**: Apply damage and spawn VFX marker projectile
- **`server_find_best_target`**: Cone-based targeting with LOS checks

#### 4. Client Rendering (`src/client_renderer.odin`)
- Extended hotbar to 5 slots (adjusted layout)
- Added spell type code 5 for lightning
- Camera kick on cast: `0.032` with FOV kick `0.45`
- Lightning strikes passed to shader uniforms

#### 5. Client Prediction (`src/client_prediction.odin`)
- Added `lightning_strikes: Lightning_Strikes` to `Client_World`
- Impact spawning triggers lightning strike VFX for Call_Lightning impacts
- Lightning strikes update and fade each frame

#### 6. Shader VFX (`shaders/scene.glsl`)
- Added `vec4 lightning[8]` uniform (ground pos + age)
- Lightning spell tint: brilliant white-blue `(0.92, 0.95, 1.00)`
- Volumetric rendering:
  - **Main bolt**: Thick segment from ground to 45m sky (radius 0.35)
  - **Arc branches**: 3 jagged segments with time-animated offsets
  - **Ground bloom**: 2.5m radius corona at impact
  - **Intensity**: Quadratic fade based on age

### Network Protocol
- No protocol changes needed
- Lightning impacts piggyback on projectile system
- Server spawns zero-velocity "marker" projectile at impact site
- Client converts vanishing marker → impact + lightning strike VFX

## Controls
- Press **`5`** to select Call Lightning
- Hold **LMB** to cast (1.8s channel)
- Aim at enemy during cast
- Release has no effect (cast completes automatically)

## VFX Description
The lightning bolt is rendered as:
1. **Primary bolt**: Thick glowing column from sky to ground, brilliant white-blue
2. **Secondary arcs**: Three branching segments that jitter with time-based offsets
3. **Ground explosion**: Large bloom at impact point
4. **Flash**: Screen-readable even in greybox, fades quickly (0.25s lifetime)

The effect uses segment_glow (beam) and corona (sphere glow) primitives in the ray-marching shader for performant volumetric rendering.

## Testing Notes
- **Range**: 22m is roughly 2x character height (1.72m), balanced for medium-range dueling
- **Cast time**: 1.8s is long enough to require commitment but usable in combat
- **Damage**: 85 direct + 34 AoE max = 119 total if both hit, comparable to Frost Lance piercing potential
- **Mana**: 60 cost = 60% of max mana pool, heavy investment
- **Targeting**: Cone threshold of 0.85 dot (~32° cone) requires reasonably accurate aim
- **LOS validation**: Cannot hit around corners - target must maintain LOS throughout entire 1.8s cast
  - **Test**: Start cast, have target duck behind pillar → cast fails, mana/cooldown refunded
  - **Test**: Target stays in open → strike lands successfully

## Known Limitations
- No casting animation (reuses idle pose)
- Cast cannot be interrupted (future: death/stun should cancel)
- No audio (audio pipeline TBD)
- No casting bar in UI (could add progress indicator)

## Build Instructions
1. **Shader compilation required**:
   ```bash
   sokol-shdc -i shaders/scene.glsl -o src/scene.odin \
              -l hlsl5:glsl430:metal_macos:wgsl -f sokol_odin
   ```
2. Build server and client normally:
   ```bash
   ./build.sh both        # Linux
   .\build.ps1 -Target both  # Windows
   ```

## Future Enhancements
- Cast interrupt on damage/death
- Casting progress bar in HUD
- Thunder sound effect
- Sky darkening effect during cast
- Multiple bolts for AOE-focused variant
- "Overcast" passive: reduces range but removes cast time
