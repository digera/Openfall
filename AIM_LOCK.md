# Auto-Aim Lock (RMB)

Hold **right mouse button** to lock aim onto the current sticky soft-target. View smoothly pulls toward target center (chest/eye height) while **draining stamina at 28/s** (higher than sprint). Lock breaks when RMB released or stamina depletes.

## Design

**Costly choice, not a default:**
- 28/s stamina drain (vs 24/s sprint) → ~3.5 seconds on full bar
- Mutually exclusive with sprint
- Only drains when locked on a valid hostile target (not when RMB idle)
- Fair assist: 3.5 rad/s smooth pull, not instant snap

## Implementation

### Client (`src/main_client.odin`)
- `client_apply_aim_assist()` returns `true` when assist runs
- `aim_lock` flag only set when assist succeeds (valid hostile target, alive, stamina > 0)
- Smooth pull toward chest height (1.4m), handles yaw wrap-around

### Server (`src/simulation.odin`)
- `STAMINA_AIM_LOCK_DRAIN = 28.0/s` constant
- Drains stamina when `input.aim_lock` flag is set
- Cannot sprint while aim-locked (`!aim_locking` in sprint condition)

### Network (`src/network.odin`)
- Protocol v5→v6 (incompatible with old clients)
- `aim_lock` flag serialized as bit 2 in input flags byte

## Tuning

| Constant | Value | File | Effect |
|----------|-------|------|--------|
| `STAMINA_AIM_LOCK_DRAIN` | 28.0/s | `simulation.odin` | Cost (higher = fewer locks) |
| `AIM_ASSIST_STRENGTH` | 3.5 rad/s | `main_client.odin` | Pull speed (higher = stronger) |
| `AIM_ASSIST_TARGET_HEIGHT` | 1.4 m | `main_client.odin` | Aim point (chest/eye) |

## Testing Checklist

**Lock activation:**
- [ ] RMB + no target → no assist, no drain
- [ ] RMB + hostile target → view pulls, stamina drains 28/s
- [ ] RMB + friendly target → no assist, no drain
- [ ] Release RMB → assist stops immediately

**Stamina:**
- [ ] Lock drains at 28/s (faster than sprint)
- [ ] Stamina = 0 → lock breaks instantly
- [ ] Cannot sprint while locked (mutual exclusion)
- [ ] Regenerates when not locked/sprinting

**Edge cases:**
- [ ] Target dies mid-lock → lock breaks
- [ ] Player dies → no lock possible
- [ ] Mouse unlock (ESC) → RMB cleared
- [ ] Aim away from target → sticky retargets or drops
- [ ] Yaw at ±180° → smooth rotation (no spin)

**Server authority:**
- [ ] Modified client cannot bypass stamina cost
- [ ] Old v5 clients cannot connect

## Lock Break Conditions

Lock ends when:
1. RMB released
2. Stamina depletes (server sets to 0)
3. Target dies/lost
4. Target becomes friendly
5. Player dies
6. Mouse unlocked

All conditions verified client-side; stamina drain is server-authoritative.
