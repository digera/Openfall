# Testing Notes: Tower Damage Visualization (PR #31)

## Quick Test

1. Build: `./build.sh` (Linux) or `.\build.ps1` (Windows)
2. Run server: `./bin/nexus_server` (or `.exe` on Windows)
3. Run client: `./bin/nexus_client`
4. Join a team (1/2/3 for Ember/Tide/Verdant)
5. Mine any tower with beam (hold LMB on spell 6) or projectiles

## What to Look For

### ✅ Expected (Good)
- **Chip damage visible**: When you damage a node from 100% → 50% HP, it should shrink dramatically (not just a tiny bit)
- **Silhouette deforms**: The tower should visibly thin out, lose mass, and deform as you mine
- **Readable gaps**: When nodes die, clear gaps should appear in the shell
- **Core visible**: As the shell thins, you should see the thin core (0.55m cylinder) through gaps
- **Progressive feedback**: Visual feedback should scale smoothly with damage (25% HP node looks clearly worse than 50% HP)

### ❌ Before Fix (Bad)
- Tower looked frozen/static during mining
- No visual change until nodes fully died
- Silhouette stayed mostly intact until completely destroyed
- Awkward disconnect between damage dealt and visuals

## Tower Positions

- **0**: Golden tower (center plaza, toughest)
- **1, 2, 3**: Near-lane towers (one per team)
- **4, 5, 6**: Far-lane towers (one per team)

## Technical Details

### Scaling Comparison

| HP % | Old Radius | New Radius | New Intensity | Combined Effect |
|------|------------|------------|---------------|-----------------|
| 100% | 100%       | 100%       | 100%          | 100%            |
| 50%  | 81%        | 60%        | 70%           | 42%             |
| 25%  | 72%        | 40%        | 55%           | 22%             |

**Key improvement:** 50% HP node now shows at 42% visual presence (was 81%), making chip damage dramatically more readable.

### Paint Parameters (Tunable)

In `src/tower_nodes.odin`, `tower_paint_occupancy`:
- Radius: `r := t.node_radius * (0.20 + 0.80 * hp_frac)`
- Intensity: `hp_occ_scale := 0.40 + 0.60 * hp_frac`

If damage feels too subtle or too dramatic, these coefficients can be adjusted.

## Success Criteria

From original issue:

1. ✅ While mining, tower visuals clearly react to damage **before** the whole tower is gone
2. ✅ Chips and kills must be readable in the silhouette/surface (not just ore popping)
3. ✅ When nodes die, the tower's drawn volume should shrink/lose mass matching `live_count`
4. ✅ No dual gameplay authority for towers (pylons dormant)
5. ✅ Server authority and wire format kept (no protocol bump)
6. ✅ TOWERS.md updated so authority vs paint is accurate

## Known Limitations (Out of Scope)

- No smooth interpolation between node positions (instant resort)
- No fancy node mesh geometry (sphere SDFs only)
- No per-node destruction VFX
- No bot AI targeting specific low-HP nodes

These are intentional future improvements that don't block this fix.
