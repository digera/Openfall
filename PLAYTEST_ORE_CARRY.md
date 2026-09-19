# Playtest Guide: Ore Carry & Dump System

## What changed

**Before:** Walking over ore chunks instantly banked them to your team wallet.

**Now:** You must carry ore back to your team's dump zone at base to bank it.

## Test scenarios

### 1. Basic pickup and dump
1. Mine a tower (beam or projectile)
2. Ore chunks drop → walk over one
3. **Expected:** Server log shows "picked up X ore (now carrying Y)"
4. Walk back to your team base (back area, where you spawn)
5. **Expected:** Standing in the 8m dump zone triggers "banked X ore", carry clears

### 2. Stacking same ore
1. Pick up one chunk of Ember ore
2. Walk over another Ember chunk
3. **Expected:** Second chunk adds to carry total
4. Try to pick up Tide ore while carrying Ember
5. **Expected:** Rejected (carry is single-kind)

### 3. Death drop
1. Pick up ore (e.g. 10.0 gold from minion)
2. Let an enemy kill you
3. **Expected:** Loose chunk spawns at death position (slightly above, z+0.35)
4. Anyone can walk over and reclaim it

### 4. Leave dump early
1. Pick up ore
2. Walk **into** dump zone briefly
3. Walk **out** before banking completes (if tick-based; check logs)
4. **Expected:** Ore still in carry if you left before server banked it

### 5. Enemy dump does nothing
1. Pick up your team's ore
2. Walk into an enemy team's dump zone
3. **Expected:** No banking, ore stays in carry

### 6. Respawn clears carry
1. Pick up ore
2. Wait for respawn timer to expire (or suicide into a tower)
3. **Expected:** Respawn with empty hands, no ore in carry

## Dump zone locations

Each team's dump is an **8 m radius circle** at:
- **Ember (red):** North back of base (team angle 90°, pushed +2m behind spawn line)
- **Tide (blue):** 210° (120° clockwise from Ember)
- **Verdant (green):** 330° (240° clockwise from Ember)

All at floor level, slightly behind the spawn fan.

## Debug output

Look for these server logs:
- `[Ore] <id> picked up <amt> <kind> (now carrying <total>)`
- `[Ore] <id> banked <amt> <kind>`
- `[Death] Entity <id> dropped <amt> <kind>`

## Client notes

**Carry state is synced** in snapshots (`carrying_ore`, `carrying_ore_amount`), but **HUD display is not implemented** in this PR. The data arrives at the client; rendering/UI is future work.

## Known constraints

- **Carry limit:** `ORE_CARRY_LIMIT = 999.0` (effectively no cap; chunks always fit)
- **Dump check:** Distance to dump center, XY only (ignores Z)
- **Pickup reach:** `CHUNK_PICKUP_R = 1.1` m from body mid-height
- **Death drop:** Single `ore_chunk_spawn_loose` call (not scattered; spawns at one point)

## What's unchanged

- Tower mining (beams/blasts) → chunks spawn as before
- Minion death → `MINION_ORE_DROP` spawns loose chunks
- Chunk physics (gravity, bounce, settle, lifetime)
- Wallet spending (waves, essence scoring) all work once ore is banked
