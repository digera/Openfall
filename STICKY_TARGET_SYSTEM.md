# Sticky Target System

## Overview

The sticky target system provides soft-target selection for spells and abilities. While aiming, the last living enemy entity your crosshair touches becomes your persistent **sticky target** until you aim at a different valid entity or the target dies/becomes invalid.

## Features

- **Client-side raycasting**: Each frame, a hitscan ray is cast from the camera through the crosshair against remote entity cylinders
- **Sticky behavior**: The target persists until:
  - You aim at a different valid entity
  - The target dies
  - The target becomes inactive (e.g., disconnects or times out)
- **Target HUD modal**: Displays below the crosshair showing:
  - Entity display name (e.g., "Wisp-03" for bots, "Player-N" for human players)
  - Current health as a colored HP bar and numeric value
- **Team-colored display**: The target name is rendered in the entity's team color

## Implementation Details

### Entity Names

**Server-side:**
- Bot names: `Wisp-01`, `Wisp-02`, etc. (assigned on spawn in `bots.odin`)
- Player names: `Player-1`, `Player-2`, etc. (assigned on join in `server.odin`)
- Names stored in `Entity_World.names` (32-byte fixed strings with length)

**Network:**
- Names included in `Snapshot_Entity` packets
- Wire format: 1 byte length + up to 32 bytes for name text
- Average entity snapshot size: ~58 bytes (up from ~42), still well under MTU

### Client-side Tracking

**Data structures:**
- `Client_World.sticky_target_id`: Currently targeted entity ID (or `INVALID_ENTITY`)
- `Client_World.sticky_target_name`: Cached name of the current target
- `Remote_Entity.name`: Display name for each remote entity

**Raycasting:**
- Function: `client_world_update_sticky_target()`
- Performs ray-cylinder intersection against all active remote entities
- Uses the same collision geometry as lag-compensated hitscan (CHARACTER_RADIUS_M × CHARACTER_HEIGHT_M cylinders)
- Maximum targeting range: 100 meters
- Updates sticky target ID when a new entity is hit

**Validation:**
- `client_world_is_valid_target()`: Checks if target is still alive and active
- Called each frame in `client_world_update()` to clear invalid targets

### HUD Rendering

**Location:** Below crosshair (row cy + 2.5)

**Components:**
1. Entity name (centered, team-colored)
2. HP bar (14 characters wide) + numeric HP value
3. Color-coded by health:
   - Green (>60% HP)
   - Yellow (30-60% HP)
   - Red (<30% HP)

**Function:** `hud_draw_target_modal()` in `client_renderer.odin`

## Usage for Future Spells

### Reading the Sticky Target

Spell implementations can read the sticky target from the client world:

```odin
if gc.client_world.sticky_target_id != INVALID_ENTITY {
    target_id := gc.client_world.sticky_target_id
    // Use target_id for spell targeting (e.g., Call Lightning, Heal Other)
}
```

### Validation Hook (Server-side)

For server-authoritative spell validation:

1. Client sends `sticky_target_id` alongside cast input
2. Server validates:
   - Target is alive and active
   - Target is in range
   - Target meets spell requirements (e.g., is an enemy for damage spells, is friendly for healing)
3. Server performs lag compensation if needed

**Extension point:** The `Input_State` struct can be extended with a `target_entity_id` field for spells that need explicit targeting.

## Future Enhancements

### Friendly Targeting

Currently, the system targets **all other entities** (no friendly-fire filtering on the client raycast). To support healing spells:

- Keep current behavior (allows targeting anyone)
- Server-side spell validation enforces targeting rules per spell type
- Future: Add visual differentiation (e.g., different HUD color for friendly vs enemy targets)

### Target Priority

For overlapping targets, closest entity wins. Future options:

- Prefer enemies over friendlies (client-side filter)
- Prefer low-HP targets
- Target "stickiness" timer to avoid flicker when crosshair sweeps across multiple targets

### Extended HUD Info

Potential additions to target modal:

- Status effects (e.g., "SLOWED")
- Mana bar (for friendly targets)
- Distance to target
- Target's current spell cooldowns (for allies)

## Code Locations

| File | What |
|------|------|
| `src/entity.odin` | `Entity_Name` struct and helper functions |
| `src/client_prediction.odin` | Sticky target tracking, raycasting, validation |
| `src/main_client.odin` | `client_update_sticky_target()` call in game loop |
| `src/client_renderer.odin` | `hud_draw_target_modal()` HUD rendering |
| `src/network.odin` | `Snapshot_Entity` with name fields, serialization |
| `src/server.odin` | Name assignment for players, snapshot building |
| `src/bots.odin` | Name assignment for bots |

## Testing

1. Start server: `./bin/nexus_server`
2. Start client: `./bin/nexus_client`
3. Join a team and aim at bots/players
4. Verify:
   - Target name appears below crosshair when aiming at an entity
   - HP bar updates as target takes damage
   - Target persists when you look away slightly
   - Target clears when you aim at a different entity or target dies
