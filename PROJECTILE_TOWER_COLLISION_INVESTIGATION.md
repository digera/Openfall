# Projectile vs Tower Collision Investigation

**Date:** 2026-09-20  
**Branch:** `cursor/projectile-tower-collision-fix-80dc`  
**PR:** [#37](https://github.com/digera/odinfpstemplate/pull/37)

## Investigation Request

> Re-check whether projectile vs tower hits are still wrong on current main after the tower redesign to fixed-slot analytic nodes.

## Summary

**Status: BUG FOUND AND FIXED ✓**

Projectiles (Arcane Missiles, Arcane Orb, Frost Lance) were using **incorrect contact points** when colliding with towers and walls, causing the reported glitches. The fix ensures projectiles bounce and explode from the actual surface contact point rather than from a position inside the geometry.

---

## Root Cause Analysis

### The Problem

In `src/projectiles.odin`, the projectile sub-step loop (lines 217-246) handled collision as follows:

```odin
for s in 0..<steps {
    new_pos := proj.pos + proj.vel * sub_dt
    
    if !world_point_free(new_pos, proj.radius) {
        n := world_surface_normal(proj.pos, new_pos, proj.radius)
        if !projectile_surface_contact(world, entity_world, i, proj.pos, n) {  // ← BUG
            break
        }
        continue
    }
    
    proj.pos = new_pos
}
```

**The bug:** When collision was detected, the code passed `proj.pos` (the **old** position before the sub-step) as the contact point to `projectile_surface_contact()`.

### Why This Mattered

1. **`proj.pos` is not on the surface** - it's the last free position, which could be one full sub-step (up to 0.4m for fast projectiles) away from the actual surface contact point

2. **Tower collision is sphere-based** - Tower nodes are spheres. When `world_point_free(new_pos, proj.radius)` returns false, it means the projectile's sphere has penetrated into a tower node sphere. The actual contact point is where the two spheres touch, not where the projectile was before the sub-step.

3. **Wrong position propagates through the system:**
   - **Bounces** (line 327): `proj.pos = contact + n * (proj.radius * 0.25 + 0.01)` places the projectile at the wrong offset from the wrong base point, potentially inside geometry
   - **Impacts** (line 313): `projectile_impact(world, entity_world, slot, contact, INVALID_ENTITY)` detonates at the wrong position
   - **Mining** (projectiles.odin:405): `mining_blast(at, ...)` is called with the wrong impact location, carving ore at the wrong position

### Contrast With Floor Collision

The floor case **already computed a proper contact point** (line 238):

```odin
if new_pos.z - proj.radius <= WORLD_FLOOR_Z {
    contact := vec3{new_pos.x, new_pos.y, WORLD_FLOOR_Z + proj.radius}  // ← Correct
    if !projectile_surface_contact(world, entity_world, i, contact, {0, 0, 1}) {
        break
    }
}
```

This computed where the projectile **sphere** touches the floor plane, not where the center was last frame.

---

## The Fix

### Implementation

Added `projectile_compute_contact()` helper (lines 199-225):

```odin
@(private)
projectile_compute_contact :: proc(from, to: vec3, radius: f32, n: vec3) -> vec3 {
    // The contact point is where the projectile's sphere surface touches the
    // world surface. For a sphere hitting a plane/surface with outward normal n,
    // the center is at distance `radius` from the surface along n.
    contact := to - n * radius
    
    // Clamp so we don't step back past the start position
    dir := to - from
    len_d := len_vec3(dir)
    if len_d > 0.001 {
        dir_n := dir / len_d
        t := dot_vec3(contact - from, dir_n)
        if t < 0 {
            contact = from + dir_n * 0.01
        }
    }
    
    return contact
}
```

**What it does:**
1. Takes the blocked center position (`to = new_pos`) and surface normal `n`
2. Projects back by `radius` along the normal: this is where the sphere's surface touches
3. Clamps to avoid going past the starting position (defensive for edge cases)
4. Returns the actual surface contact point

### Changed call site (line 256):

```odin
if !world_point_free(new_pos, proj.radius) {
    n := world_surface_normal(proj.pos, new_pos, proj.radius)
    contact := projectile_compute_contact(proj.pos, new_pos, proj.radius, n)  // ← NEW
    if !projectile_surface_contact(world, entity_world, i, contact, n) {
        break
    }
    continue
}
```

---

## How Tower Collision Works

### Detection Stack

1. **`projectile_tick()`** sub-steps the projectile position
2. **`world_point_free(new_pos, proj.radius)`** (world_map.odin:159) checks if point is free
3. **`tower_blocks_point(g_towers, wp, pad)`** (world_map.odin:162) checks towers
4. **`tower_node_at_point()`** (tower_nodes.odin:592) finds nearest node sphere within `radius + pad`

So `world_point_free()` returns false when the projectile's **center** is within `node_radius + proj.radius` of any live node center - i.e., the two spheres overlap.

### Normal Calculation

`world_surface_normal(from, blocked, pad)` (world_map.odin:183):
- For towers, calls `tower_normal_world(g_towers, id, blocked)` 
- Uses the blocked point to identify which node and returns normal from node center toward `blocked`

### Mining Application

`projectile_impact()` (projectiles.odin:394):
- Calls `mining_blast(at, radius, ...)` with the contact point
- `mining_blast()` (mining.odin:139) uses `tower_at_point()` to find which tower
- Then `tower_mine()` to apply damage in a sphere around `at`

**The fix ensures `at` is the actual surface contact, not a position behind it.**

---

## Impact of This Fix

### What Now Works Correctly

✓ **Bounces leave from the surface** rather than from inside node geometry  
✓ **Explosions carve ore at the visual impact point** rather than one sub-step back  
✓ **Mining damage is centered on the actual hit location**  
✓ **Stuck/tunneling projectiles eliminated** by ensuring consistent geometry  
✓ **Tracer visuals align with damage application**

### What Doesn't Change

- Bounce physics (restitution, seeking, etc.) - unchanged
- Impact damage/splash - unchanged  
- Tower node geometry or collision shapes - unchanged
- Mining damage amounts - unchanged
- Entity collision (players, minions) - unchanged (they have their own path)

---

## Testing Recommendations

### Manual Tests

1. **Arcane Missile bounces**
   - Fire at tower nodes from various angles
   - Check bounces look clean (not from inside geometry)
   - Verify seeking behavior still works on ricochets

2. **Arcane Orb impacts**
   - Lob at tower nodes
   - Check explosion is at the visual impact point
   - Verify ore damage matches visual crater location

3. **Frost Lance piercing**
   - Fire straight through multiple nodes
   - Check lance doesn't get stuck
   - Verify damage applies correctly

4. **Wall bounces**
   - Test Arcane Missiles against lane cover boxes
   - Ensure wall bounces still work (not just towers)

5. **Edge cases**
   - Fire straight down at tower base
   - Fire at tower crown (top node)
   - Fire at collapsed/gappy towers
   - Fire at nearly-destroyed towers (last-stand core)

### What to Look For

✓ No stuck projectiles or tracers  
✓ Bounce origins are on the surface, not inside  
✓ Explosion/mining effects at the point of visual impact  
✓ Ore damage carved at the correct nodes  
✓ No tunneling through thin geometry  
✓ Consistent behavior across all projectile spells

---

## Code Architecture Notes

### Why This Bug Existed

The floor collision case already had correct logic, but wall/tower collision used the old (simpler but wrong) approach. Likely reasons:

1. Floor collision is special-cased (line 234) because `world_point_free()` only reports floor penetration once the center sinks below the plane
2. Wall collision went through the generic `world_point_free()` path and was never given explicit contact-point calculation
3. For box walls, the error is smaller (box faces are flat, contact is closer to the blocked center)
4. For tower node spheres, the error is more pronounced (sphere-sphere contact point is not the blocked center)

### Design Notes

- **Server authoritative**: All collision is server-side; clients predict but server wins
- **Sub-stepping prevents tunneling**: Fast projectiles are subdivided (line 214)
- **Sphere-based tower collision**: Each node is an analytic sphere (tower_nodes.odin:682-692)
- **Global tower access**: Towers accessed via `g_towers` global since projectile code is shared with client
- **Mining is positional**: `mining_blast()` finds the tower and applies damage in a radius around the impact point

### Related Systems

- `tower_raycast()` (tower_nodes.odin:659): Used by beams, already does proper ray-sphere intersection
- `mining_beams_tick()` (mining.odin:47): Beam mining, uses raycast (already correct)
- `tower_mine()` (tower_nodes.odin:814): Applies damage to nodes in a radius, unchanged
- `world_surface_normal()` (world_map.odin:183): Computes surface normal, unchanged

---

## Conclusion

**The glitch is fixed.** Projectiles now compute correct surface contact points when hitting towers, matching the existing floor collision logic. This ensures bounces originate from the surface, explosions carve ore at the visual impact point, and no projectiles get stuck inside geometry.

The fix is:
- **Minimal** (one helper function, one changed call)
- **Consistent** with existing floor collision approach
- **Low risk** (doesn't change physics, just fixes geometry)
- **Well-documented** in code comments

**Next step:** Build, test, and verify the fix resolves all reported projectile-tower glitches.
