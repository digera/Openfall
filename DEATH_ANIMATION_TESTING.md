# Death Animation Testing Guide

## Build Requirements

Before testing, the shader must be compiled with `sokol-shdc`:

**Windows:**
```powershell
.\build.ps1
```

**Linux:**
```bash
./build_graphical_client.sh
```

This will regenerate `src/scene.odin` from `shaders/scene.glsl` with the updated uniforms and constants.

## Visual Testing

### 1. Basic Death Animation
1. Launch server: `.\bin\nexus_server.exe` (or `./bin/nexus_server`)
2. Launch client: `.\bin\nexus_client.exe` (or `./bin/nexus_client`)
3. Join a team and find a bot or another player
4. Deal fatal damage and observe:
   - **0.0-0.4s:** Robe inflates smoothly, brightening as it swells
   - **At 0.4s:** Robe and motes vanish, bright flash appears
   - **0.4-0.52s:** Flash fades quickly
   - **After 0.52s:** Wisp is hidden until respawn (4 seconds from death)

### 2. Multiple Simultaneous Deaths
1. Set up a scenario with multiple bots
2. Use AoE spells (Arcane Orb, Call Lightning splash) to kill several at once
3. Verify each wisp animates independently with proper timing

### 3. Spectator View
1. Have one player die
2. Another player watches from various distances and angles
3. Verify the animation is visible and synchronized for all viewers

### 4. First-Person Death
1. Let the local player die
2. Verify:
   - No crash or rendering artifacts
   - The respawn countdown still shows
   - If implemented, local flash effect feels appropriate

## Performance Testing

Run with `NEXUS_BOT_DEBUG=true` to see bot positions, then:

1. Spawn multiple bots: `$env:BOTS_PER_TEAM = "5"` (Windows) or `BOTS_PER_TEAM=5` (Linux)
2. Trigger multiple deaths in quick succession
3. Monitor frame rate - should remain stable (the pop flash is cheap, similar to existing impact effects)

## Edge Cases

### Rapid Death/Respawn
1. Set fast respawn with modified `RESPAWN_DELAY_SEC` in `death_respawn.odin` (optional)
2. Kill and respawn the same wisp multiple times
3. Verify animation resets properly each time

### Lag/Interpolation
1. Simulate packet loss or high latency
2. Verify the death animation triggers on the correct frame when snapshots arrive
3. Remote wisps already use interpolation for position - death animation should sync with that

### Death While Moving
1. Kill a wisp that's sprinting or mid-air
2. Verify the cloth simulation during inflate respects momentum
3. The pop should still trigger cleanly regardless of velocity

## Rendering Details

**Inflate timing:** 0.40 seconds
- Robe radii scale: 1.0 → 1.8x (quadratic ease-out)
- Brightness: 0.0 → 1.5 additive tint (quadratic)

**Pop timing:** 0.12 seconds
- Flash radius: 0.8m → 2.0m
- Intensity: 1.0 → 0.0 (quadratic falloff)

## Known Limitations

- No sound effects (out of scope for this PR)
- First-person death doesn't add a local camera flash (could be added later)
- The cloth stops simulating after the pop; if respawn happens mid-animation (shouldn't in normal gameplay), the robe resets cleanly via the `settled = false` path
