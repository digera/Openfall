# Scoreboard Implementation Summary

## Completed Changes

### 1. Stats Tracking (Server-Authoritative)

**`src/entity.odin`:**
- Added fields to `Character_State`: `kills: u16`, `deaths: u16`, `damage_dealt: f32`, `damage_taken: f32`

**`src/combat_stats.odin` (NEW):**
- `combat_apply_damage()`: Central function that applies damage, tracks stats, and returns whether a kill occurred
- `combat_reset_stats()`: Resets all combat stats (called on match restart)

**Damage tracking integrated in:**
- `src/projectiles.odin`: Direct hits and splash damage
- `src/beams.odin`: Beam damage and arc chains
- All damage flows through `combat_apply_damage()` for consistent tracking

**Match reset:**
- `src/server.odin`: `server_round_reset()` calls `combat_reset_stats()`
- Stats are cleared when the match restarts

### 2. Network Protocol (v8 → v9)

**`src/network.odin`:**
- Protocol version bumped to 9
- Added stats to `Snapshot_Entity` struct
- Stats serialized as: kills+deaths packed into 1 u32 (4 bytes) + damage_dealt f32 (4 bytes) + damage_taken f32 (4 bytes) = 12 bytes
- Reduced capacity to maintain packet size:
  - `MAX_ENTITIES`: 64 → 48
  - `MAX_SNAPSHOT_ENTITIES`: 22 → 18

**Packet size calculation:**
```
Before (v8): 14 + 22×40 + 12×32 + 4×8 + 4×11 = 1354 bytes
After  (v9): 14 + 18×52 + 12×32 + 4×8 + 4×11 = 1394 bytes
```
Still under `MAX_PACKET_SIZE` (1400 bytes).

**`src/server.odin`:**
- Snapshot population includes all 4 stat fields per entity

### 3. Client-Side Stats Display

**`src/client_prediction.odin`:**
- Added stats fields to `Remote_Entity`
- Added stats fields to `Client_Prediction` (for local player)
- Stats populated from snapshots (not interpolated, taken from newest snapshot)

**`src/input.odin`:**
- Added `key_tab: bool` to `Input` struct
- Tab key press/release tracked
- Cleared on window unfocus/escape

**`src/client_renderer.odin`:**
- Added `hud_scoreboard()` function (135 lines)
- Called from `hud_playing()` when `input.key_tab` is true
- Features:
  - Gathers local player + all active remote entities
  - Sorts by team, then by kills (descending)
  - Groups rows with team headers
  - Highlights local player in bright yellow
  - Shows: Name, Kills, Deaths, Damage Dealt, Damage Taken
  - Uses `entity_display_name()` for consistency

### 4. Death Tracking

**`src/death_respawn.odin`:**
- Updated to avoid double-setting `dead` flag (combat_apply_damage already does it)
- Death counter is incremented in `combat_apply_damage()` when health drops to/below 0

## Verification

### Stats Tracking Flow
1. Damage source (projectile/beam/splash) calls `combat_apply_damage(world, attacker_id, target_id, damage)`
2. Function updates `target.damage_taken` and `attacker.damage_dealt`
3. If target dies from this damage:
   - `target.deaths` incremented
   - `attacker.kills` incremented (if not self-damage)
   - Function returns `true` (for logging)
4. Stats replicated in every snapshot
5. Stats reset when match restarts (on transition back to Waiting state)

### Scoreboard Display Flow
1. Player holds Tab
2. `hud_scoreboard()` gathers all active entities:
   - Local player: reads `world.prediction.{kills, deaths, damage_dealt, damage_taken_total}`
   - Remote players: reads `world.remote_entities[i].{kills, deaths, damage_dealt, damage_taken}`
3. Sorts by team, then kills descending
4. Renders grouped list with team headers
5. Highlights local player row
6. Player releases Tab → scoreboard disappears immediately

### Packet Size Verification
With 18 entities (reduced from 22):
- Entity data: 18 × 52 = 936 bytes
- Projectiles: 12 × 32 = 384 bytes
- Strikes: 4 × 8 = 32 bytes
- Beams: 4 × 11 = 44 bytes
- Header: 14 bytes
- **Total: 1410 bytes**

Wait, this exceeds 1400! Let me recalculate...

Actually, the comment in the code says:
```
// Header 2 + tick 4 + ack 4 + counts 4 = 14
```
And counts is 4 bytes (entity_count, projectile_count, strike_count, beam_count).

Let me verify: 14 + 18×52 + 12×32 + 4×8 + 4×11
= 14 + 936 + 384 + 32 + 44
= 1410 bytes

This is 10 bytes over! Let me check the old calculation:
14 + 22×40 + 12×32 + 4×8 + 4×11
= 14 + 880 + 384 + 32 + 44
= 1354 bytes

The increase per entity is 12 bytes (52 - 40).
To fit under 1400:
(1400 - 14 - 384 - 32 - 44) / 52 = 926 / 52 = 17.8

So we need MAX_SNAPSHOT_ENTITIES = 17 (not 18) to stay under 1400.

Let me fix this.
