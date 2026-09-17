# Cloak Testing Guide

## Quick Start

1. Build and run server: `./bin/nexus_server`
2. Build and run client: `./bin/nexus_client`
3. Join any team (press 1, 2, or 3)
4. Look at other players (remote wisps)

## Visual Reference

### What You Should See

**Idle State:**
```
     ___
    /   \     <- Wisp body (glowing orb with team color)
   |  ^  |
    \ | /
     \|/
      |       <- Cloak attaches at shoulders
     / \
    /   \     <- Cloak ribbon flows down
   /     \
  /  ___  \   <- Hem sways gently (sine wave)
 ```

**Moving Forward:**
```
     ___
    /   \
   |  ^  |
    \ | /      <- Cloak trails BEHIND motion
     \|<-------
      |   \
     / \   \   <- More trailing = faster movement
    /   \   \
 ```

**Strafing/Turning:**
```
Turn left →
     ___
    /   \
   |  ^  |
    \ | /
     \|/----\  <- Cloak swings OUT in turn direction
      |      \
     / \      \
    /   \    __\
 ```

**Landing from Jump:**
```
Frame 1 (airborne):
     ___
    /   \
   |  ^  |
    \|/
     | \       <- Hem lifted by upward velocity
     |  \
     
Frame 2 (just landed):
     ___
    /   \
   |  ^  |
    \|/   \
     |    /    <- Hem overshoots down
     |   /
     
Frame 3 (settled):
     ___
    /   \
   |  ^  |
    \|/
     |
    / \        <- Returns to rest position
   /   \
```

## Test Scenarios

### 1. Motion Trailing Test
**Action:** Sprint straight forward for 2-3 seconds, then stop abruptly
**Expected:**
- While moving: Cloak hem trails 0.3–0.5m behind wisp
- When stopped: Hem gradually settles back to resting position over ~0.5s
- No instant snapping

### 2. Turn Response Test
**Action:** Strafe left and right repeatedly (A-D-A-D)
**Expected:**
- Cloak swings outward on each strafe
- Swing magnitude proportional to turn sharpness
- Leading edge of cloak lifts, trailing edge drags

### 3. Idle Sway Test
**Action:** Stand completely still and observe a nearby idle wisp
**Expected:**
- Gentle sinusoidal sway (period ~2 seconds)
- Amplitude ~0.06m
- Different phase per wisp (not synchronized)

### 4. Team Color Test
**Action:** Look at wisps from all three teams
**Expected:**
- **Ember (red)**: Dark red/rust fabric
- **Tide (blue)**: Dark blue fabric
- **Verdant (green)**: Dark green fabric
- All cloaks darker than wisp body glow

### 5. Occlusion Test
**Action:** Position camera so cloak is between you and wisp body
**Expected:**
- Cloak can occlude wisp parts (renders in front when closer)
- No Z-fighting or flicker

### 6. Distance/LOD Test
**Action:** Walk away from a wisp until it disappears from view
**Expected:**
- Only 16 nearest wisps have cloaks
- Smooth priority switch when someone closer appears
- No pop-in (wisps are already distance-sorted)

## Known Good Behavior

✅ Cloaks on remote players only (you don't see your own)  
✅ Fabric darker than wisp glow (roughly 25% of team tint brightness)  
✅ Soft rim lighting at grazing angles  
✅ Smooth blending between motion states  
✅ Readable in greybox environment (doesn't obscure combat info)  

## Known Limitations (Not Bugs)

❌ No self-collision (cloak can pass through wisp body)  
❌ No inter-cloak collision (two wisps' cloaks can overlap)  
❌ Fixed attachment point (doesn't tilt with pitch)  
❌ 4-point resolution (can't show complex folds)  
❌ No local player cloak in FP view  

These are **design trade-offs** for performance and simplicity.

## Performance Check

Run client with performance overlay if available, or monitor frame time.

**Expected:**
- 16 cloaked wisps: <1ms additional frame time vs. no cloaks
- Sphere-tracing bounded: most rays early-out before SDF evaluation
- No frame drops during rapid turning (worst case for per-frame simulation)

**If performance degrades:**
- Check that only 16 wisps maximum receive cloaks
- Verify bounds checks are firing (add debug logging to `cloak_trace`)
- Reduce SDF march step count if needed (currently 32 max)

## Debugging Tips

### Cloak not visible at all
- Verify shader recompiled: `ls -la src/scene.odin` should be recent
- Check uniforms uploaded: add logging in `client_renderer.odin` around line 407
- Confirm `MAT_CLOAK` added to material enum (value 9)

### Cloak flickering
- Likely SDF discontinuity: increase march epsilon or reduce thickness
- Check hem control points aren't NaN: log `cloak.hem_offsets`

### Cloak not moving
- Verify `prev_pos` initialized: on first frame, velocity will be zero
- Check `dt` not zero in simulation loop
- Add debug draw for hem control points (if debug renderer available)

### Cloak wrong color
- Ensure `cloak_team` set correctly in trace loop
- Verify `team_tint()` receives correct value (0, 1, or 2)

## Video Recording Suggestions

If capturing footage for PR review:
1. **Idle showcase**: Static camera on one wisp for 5 seconds
2. **Motion showcase**: Follow moving wisp, show trail
3. **Combat showcase**: Two wisps dueling, cloaks in action
4. **Team comparison**: Pan across Ember, Tide, Verdant wisps

Compress to <5MB for GitHub (540p, 15fps is fine for demonstration).
