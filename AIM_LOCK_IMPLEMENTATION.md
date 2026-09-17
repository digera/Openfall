# Auto-Aim Lock Implementation Summary

## Overview

Implemented RMB-activated auto-aim lock that smoothly pulls view toward the current sticky soft-target while draining stamina at a meaningful rate. The feature is designed as a **costly tactical choice** rather than a default behavior.

## Design Philosophy

The aim lock is intentionally balanced to prevent constant use:

- **Higher stamina cost than sprint** (28/s vs 24/s)
- **Mutually exclusive with sprint** - cannot do both simultaneously
- **Breaks immediately** when stamina depletes or RMB released
- **Requires valid hostile target** - won't work on teammates or without a target
- **Fair assist, not aimbot** - smooth pull at 3.5 rad/s, not instant snap

## Technical Implementation

### 1. Input System (`src/input.odin`)

Added right mouse button tracking:
- `held_right: bool` field in `Input` struct
- Mouse event handlers for `MOUSE_DOWN`/`MOUSE_UP` with `.RIGHT` button
- Cleared on window unfocus/mouse unlock (same as left button)

### 2. Entity Input State (`src/entity.odin`)

Added `aim_lock: bool` field to `Input_State` struct for network replication. This flag is sent with every input packet so the server can authoritatively drain stamina.

### 3. Simulation Logic (`src/simulation.odin`)

#### Stamina Drain
- Added constant: `STAMINA_AIM_LOCK_DRAIN :: f32(28.0)`
- Drains stamina when `input.aim_lock` is true and stamina > 0
- Higher drain rate than sprint to discourage constant use

#### Sprint Interaction
- Modified sprint condition: `sprinting := input.sprint && moving && char.on_ground && char.stamina > 0 && !aim_locking`
- Cannot sprint while aim-locked (exclusive stamina use)
- Stamina regeneration only when neither sprinting nor aim-locked

### 4. Network Protocol (`src/network.odin`)

#### Protocol Version Bump
- Changed from v5 to v6 to prevent old clients from connecting
- Ensures all clients send the aim_lock flag correctly

#### Input Serialization
- Updated `input_flags()` to include aim_lock as bit 2 (`f |= 4`)
- Updated deserializer to read bit 2: `in_.aim_lock = flags & 4 != 0`
- No size increase - uses existing flags byte

### 5. Client Aim Assist (`src/main_client.odin`)

#### Input Handling
- Set `gc.move_input.aim_lock = input.held_right` each frame
- Call `client_apply_aim_assist()` when RMB held and target valid

#### Aim Assist Algorithm

```odin
AIM_ASSIST_STRENGTH :: f32(3.5)       // radians per second
AIM_ASSIST_TARGET_HEIGHT :: f32(1.4)  // chest/eye height
```

The assist logic:
1. **Validates conditions**: prediction initialized, player alive, target valid and hostile, stamina > 0
2. **Calculates target direction**: from player eye to target center (chest height, not feet)
3. **Converts to angles**: uses `atan2` for yaw, `asin` for pitch
4. **Smooth pull**: limits delta to `pull_rate * dt` to avoid snap
5. **Handles wrap-around**: uses `wrap_angle()` for yaw to handle -π/+π boundary correctly
6. **Clamps pitch**: respects `CAM_PITCH_MAX` limits

### 6. Documentation (`README.md`)

Updated in two places:
1. **Controls table**: Added "Hold RMB | Aim lock: smoothly pull view toward current sticky target (drains stamina)"
2. **Combat section**: Added "Aim Lock" subsection explaining:
   - How to activate (hold RMB)
   - Stamina drain rate (28/s vs 24/s sprint)
   - Break conditions (release RMB or stamina depletes)
   - Target requirements (hostile, active sticky target)

## Testing Checklist

When testing this implementation:

### Basic Functionality
- [ ] Hold RMB with no target → no assist occurs
- [ ] Hold RMB with hostile target → view smoothly pulls toward target
- [ ] Release RMB → assist stops immediately
- [ ] Stamina depletes → assist stops, lock breaks

### Stamina Mechanics
- [ ] Stamina drains at 28/s while aim-locked
- [ ] Cannot sprint while aim-locked (mutually exclusive)
- [ ] Stamina regenerates when neither sprinting nor aim-locked
- [ ] Lock breaks cleanly when stamina hits zero

### Target Validation
- [ ] Lock only works on hostile targets (not teammates)
- [ ] Lock drops if target dies mid-hold
- [ ] Lock follows sticky target updates (retargets if crosshair moves to new enemy)
- [ ] No lock if mouse is unlocked

### Aim Assist Quality
- [ ] Pull is smooth, not instant snap
- [ ] Aims toward chest/eye height, not feet
- [ ] Yaw wrap-around works correctly (no spin-around at ±180°)
- [ ] Pitch respects camera limits (no over-pitch)

### Network Behavior
- [ ] Server correctly drains stamina (check server logs if available)
- [ ] Old v5 clients cannot connect (protocol version bump)
- [ ] Lock behavior consistent across different latencies

## Tuning Parameters

The following constants can be adjusted for balance:

| Constant | Value | Location | Purpose |
|----------|-------|----------|---------|
| `STAMINA_AIM_LOCK_DRAIN` | 28.0/s | `simulation.odin` | Stamina cost (higher = more expensive) |
| `AIM_ASSIST_STRENGTH` | 3.5 rad/s | `main_client.odin` | Pull speed (higher = stronger assist) |
| `AIM_ASSIST_TARGET_HEIGHT` | 1.4 m | `main_client.odin` | Aim point on target (chest/eye level) |

## Design Rationale

### Why higher stamina drain than sprint?

Players should **preserve stamina** rather than hold RMB constantly. At 28/s, a full stamina bar (100) lasts ~3.5 seconds of continuous aim lock. This makes it a tactical choice for critical moments, not a default behavior.

### Why mutually exclusive with sprint?

Balancing decision: aim lock is a **combat tool**, sprint is a **mobility/escape tool**. Forcing a choice prevents "god mode" where players have both perfect tracking and maximum speed.

### Why smooth pull instead of snap?

Fair competitive design. Instant snap would trivialize aiming entirely and feel like an aimbot. Smooth pull at 3.5 rad/s provides **meaningful assistance** while still requiring player positioning and timing. Fast enough to help with tracking, slow enough to reward good crosshair placement.

### Why chest/eye height instead of feet?

Most FPS games aim for center-mass. Targeting feet (entity origin) would make headshots harder and feel unnatural. 1.4m is roughly chest height, which:
- Feels natural to players
- Still requires vertical aim adjustment for headshots
- Works well with the character model (1.72m tall, eyes at 1.56m)

### Why break on stamina depletion?

Server-authoritative resource management. The server controls stamina drain, so when it hits zero, the client cannot continue locking. This prevents any client-side cheating (infinite aim lock) and makes stamina a meaningful cost.

## Future Considerations

Potential future enhancements (not implemented):

1. **Aim lock visual feedback**: Add a subtle UI indicator showing lock strength/remaining stamina
2. **Audio cue**: Sound effect when lock engages/breaks
3. **Tunable per-spell**: Different assist strengths for different spells
4. **Configuration file**: Allow server operators to tune drain/assist rates
5. **Stats tracking**: Record aim lock usage per player for balance analysis

## Commit Message

```
Add auto-aim lock feature with RMB

Implement aim lock that smoothly pulls view toward sticky soft-target while
draining stamina. Design ensures it is a costly choice, not a default.

Changes:
- Add RMB (held_right) input tracking in input system
- Add aim_lock flag to Input_State struct
- Implement server-authoritative stamina drain (28/s) for aim lock
- Prevent sprint while aim-locked (exclusive stamina use)
- Add client-side smooth aim assist toward target center (3.5 rad/s pull)
- Lock breaks when RMB released or stamina depleted
- Only assists toward hostile targets with active sticky selection
- Bump protocol version to 6 for aim_lock flag in input packets
- Update README with RMB controls and aim lock mechanics

Stamina drain rate (28/s) is higher than sprint (24/s) to ensure players
preserve stamina rather than hold RMB constantly. Assist pulls toward
chest/eye height, providing fair tracking without instant snap.
```
