# Darkfall-Style Charge-Cast Combat Implementation

## Overview

This PR implements a **charge-on-hold, fire-on-release** combat system inspired by Darkfall. Every spell now has a cast/charge time. Players hold LMB to charge their selected spell and release at any time to fire. Damage and effects scale with charge fraction (0.2 to 1.0).

## Key Changes

### 1. Spell Definitions (`src/spells.odin`)

Added `cast_time` field to `Spell_Def`:

```odin
Spell_Def :: struct {
    // ... existing fields ...
    cast_time:     f32,  // NEW: seconds to fully charge
    // ...
}
```

**Updated spell balance for slower combat:**

| Spell | Cast Time | Cooldown | Proj Speed | Notes |
|-------|-----------|----------|------------|-------|
| Arcane Missile | 0.6s | 1.2s (was 0.8s) | 24 (was 30) | Faster cast, longer CD |
| Arcane Orb | 1.2s | 7.0s (was 5.0s) | 10 (was 12) | Heavy spell, deliberate timing |
| Blink | 0.4s | 8.0s (was 6.0s) | - | Short charge for consistency |
| Frost Lance | 0.9s | 4.5s (was 3.4s) | 13 (was 15) | Slower piercing projectile |

### 2. Input System (`src/entity.odin`)

Extended `Input_State` with charge tracking:

```odin
Input_State :: struct {
    // ... existing fields ...
    cast_spell:    Spell_ID,
    charge_frac:   f32,  // NEW: [0, 1] charge fraction on release
}
```

### 3. Network Protocol (`src/network.odin`)

**Bumped protocol version to 3** to handle new charge data:

```odin
PROTOCOL_VERSION :: u8(3)  // was 2
```

Serialization now includes charge_frac as a single byte (0-255 quantized to 0-1):

```odin
// Serialize
bw_u8(&w, u8(in_.charge_frac * 255))

// Deserialize
in_.charge_frac = f32(br_u8(&r)) / 255.0
```

### 4. Client Charging Logic (`src/main_client.odin`)

Added charging state to `Game_Client`:

```odin
Game_Client :: struct {
    // ... existing fields ...
    charging_spell: Spell_ID,  // Currently charging spell
    charge_accum:   f32,       // Accumulated charge time
}
```

**Replaced `client_decide_cast`** from instant-on-hold to charge-and-release:

- While LMB held: accumulate charge toward selected spell's `cast_time`
- On release: fire if charge ≥ 20% (minimum to prevent tap-spam)
- Returns `(spell_to_cast, charge_frac)` instead of just spell ID
- Switching slots while charging cancels the charge

### 5. Server Validation (`src/server.odin`)

Updated `server_handle_spell_cast` signature:

```odin
server_handle_spell_cast :: proc(
    server: ^Server,
    caster_id: Entity_ID,
    spell_id: Spell_ID,
    charge_frac: f32,  // NEW
    tick: u32,
) -> bool
```

**Charge scaling:**
- Clamps `charge_frac` to [0.2, 1.0] (server-authoritative validation)
- For projectiles: scales damage linearly
- For Blink: scales teleport distance linearly

### 6. Projectile Damage Scaling (`src/projectiles.odin`)

`projectile_spawn` now scales damage:

```odin
scaled_damage := def.damage * spell_cast.charge_frac
```

### 7. Bot AI (`src/bots.odin`)

Updated bot casting:
- Bots always charge to 100% (`charge_frac = 1.0`)
- `cast_timer` now waits for `def.cast_time + random_delay` before next cast
- Ensures bots respect the new charge timing

### 8. HUD Charge Bar (`src/client_renderer.odin`)

Added visual feedback for charging:

```odin
if gc.charging_spell == spell && gc.charging_spell != .None {
    sdtx.color3f(0.3, 0.85, 1.0)  // Cyan
    frac := gc.charge_accum / def.cast_time
    filled := int(frac * 10)
    // Draw progress bar [=====.....]
}
```

When charging, the selected spell's slot shows a cyan progress bar instead of cooldown/ready state.

## Combat Pacing Changes

### Movement While Charging
Players can **move and look freely** while charging (Darkfall-style freedom). No rooting or movement penalties.

### Time-to-Kill (TTK)
- Increased cooldowns across the board (+25-50%)
- Added charge times (0.4-1.2s depending on spell power)
- Reduced projectile speeds slightly
- Damage now scales with charge (20-100% charge → 20-100% damage)

### Tactical Implications
- **Positioning matters more**: enemies can move during your charge
- **Charge management**: release early for chip damage or charge for lethal burst
- **Counter-play**: spot charging enemies and dodge/engage
- **Bot challenge**: bots always full-charge, requiring player positioning skill

## Wire Protocol Changes

**PROTOCOL_VERSION = 3** enforces clean client-server version matching.

Old clients (v2) cannot connect to new servers (v3), and vice versa. This prevents desyncs from missing charge_frac data.

## Testing Notes

### Build
```bash
./build.sh
./build_graphical_client.sh
```

### Manual Test
1. Start server: `./bin/nexus_server`
2. Start client: `./bin/nexus_client`
3. Join a team (press 1/2/3)
4. Select a spell (1-4)
5. **Hold LMB** → watch cyan charge bar fill in hotbar
6. **Release LMB** → fires at current charge
7. Try tap (below 20%) → no cast
8. Try partial charge → reduced damage
9. Try full charge → full damage

### Combat Test Script
```bash
./test_combat.sh  # Should pass with bots fighting using charge-cast
```

### Dominion Test
```bash
./test_dominion_match.sh  # Match should complete with slower pacing
```

## Known Behaviors

1. **Minimum 20% charge required** to fire (prevents accidental tap-spam)
2. **Switching spells cancels charge** (prevents charge-swapping exploits)
3. **Bots always full-charge** (simple AI, but effective)
4. **Charge persists across ticks** until released or cancelled
5. **Client-side charge is visual only** - server validates all casts

## Out of Scope (Future PRs)

- ✗ Map size doubling
- ✗ New Obelisk layout
- ✗ Replacing Blink with Self Heal
- ✗ Advanced bot charge timing (they full-charge for now)

## Files Changed

1. `src/spells.odin` - Added cast_time, rebalanced spells
2. `src/entity.odin` - Added charge_frac to Input_State
3. `src/network.odin` - Protocol v3, serialize charge_frac
4. `src/main_client.odin` - Charging state and logic
5. `src/server.odin` - Charge validation and scaling
6. `src/projectiles.odin` - Damage scaling by charge
7. `src/bots.odin` - Bot charge timing
8. `src/client_renderer.odin` - HUD charge bar
