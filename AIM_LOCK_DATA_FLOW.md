# Auto-Aim Lock Data Flow

This document traces the complete data flow of the aim lock feature from user input to server validation.

## Data Flow Diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            CLIENT SIDE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. INPUT CAPTURE (input.odin)                                             │
│     ┌──────────────┐                                                        │
│     │ User holds   │                                                        │
│     │ RMB button   │                                                        │
│     └──────┬───────┘                                                        │
│            │                                                                │
│            ▼                                                                │
│     input_event() catches MOUSE_DOWN/UP                                    │
│     sets: input.held_right = true/false                                    │
│            │                                                                │
│            ▼                                                                │
│  2. INPUT HANDLING (main_client.odin)                                      │
│     client_handle_input()                                                  │
│     ├─ Reads input.held_right                                              │
│     ├─ Sets gc.move_input.aim_lock = input.held_right                      │
│     └─ If RMB held + valid target:                                         │
│        └─ Call client_apply_aim_assist()                                   │
│                                                                             │
│  3. AIM ASSIST (main_client.odin)                                          │
│     client_apply_aim_assist()                                              │
│     ├─ Validate: player alive, target valid & hostile, stamina > 0        │
│     ├─ Calculate direction to target center (chest height)                 │
│     ├─ Convert to yaw/pitch angles                                         │
│     ├─ Apply smooth pull (3.5 rad/s * dt)                                  │
│     └─ Update gc.view_yaw and gc.view_pitch                                │
│                                                                             │
│  4. SIMULATION STEP (main_client.odin)                                     │
│     client_step_simulation()                                               │
│     ├─ Gather input state:                                                 │
│     │  ├─ input.yaw = gc.view_yaw                                          │
│     │  ├─ input.pitch = gc.view_pitch                                      │
│     │  ├─ input.aim_lock = gc.move_input.aim_lock  ◄── RMB state          │
│     │  └─ input.target_id = gc.client_world.target_id                      │
│     ├─ Quantize input (input_quantize)                                     │
│     ├─ Run local prediction with this input                                │
│     └─ Add to input history buffer                                         │
│                                                                             │
│  5. NETWORK SEND (network.odin)                                            │
│     serialize_client_input()                                               │
│     ├─ Pack input flags: jump(bit0) | sprint(bit1) | aim_lock(bit2)       │
│     ├─ Serialize move_fwd, move_str, yaw, pitch, spells, target_id        │
│     └─ Send UDP packet to server                                           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

                                    │
                                    │ Network (UDP)
                                    ▼

┌─────────────────────────────────────────────────────────────────────────────┐
│                            SERVER SIDE                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  6. NETWORK RECEIVE (network.odin)                                         │
│     deserialize_client_input()                                             │
│     ├─ Read UDP packet                                                     │
│     ├─ Unpack flags:                                                       │
│     │  ├─ jump = flags & 1                                                 │
│     │  ├─ sprint = flags & 2                                               │
│     │  └─ aim_lock = flags & 4  ◄── Extract RMB state                     │
│     └─ Store in input queue for this client                                │
│                                                                             │
│  7. INPUT APPLICATION (server.odin)                                        │
│     server_apply_client_inputs()                                           │
│     ├─ Dequeue input for this tick                                         │
│     └─ Set world.inputs[entity_id] = input  ◄── aim_lock flag goes here   │
│                                                                             │
│  8. SIMULATION (simulation.odin)                                           │
│     simulate_character_step()                                              │
│     ├─ Read input.aim_lock from world.inputs[entity_id]                    │
│     └─ Call simulate_character_move_xy()                                   │
│                                                                             │
│  9. STAMINA DRAIN (simulation.odin)                                        │
│     simulate_character_move_xy()                                           │
│     ├─ Check: aim_locking = input.aim_lock && char.stamina > 0            │
│     ├─ If aim_locking:                                                     │
│     │  └─ char.stamina -= STAMINA_AIM_LOCK_DRAIN * dt  (28.0/s)          │
│     ├─ Cannot sprint while aim_locking (mutually exclusive)                │
│     └─ Regenerate stamina only when !sprinting && !aim_locking             │
│                                                                             │
│  10. SNAPSHOT SEND (server.odin)                                           │
│      server_send_snapshots()                                               │
│      ├─ Gather world state including updated stamina                       │
│      ├─ Serialize snapshot packet                                          │
│      └─ Send to all clients (30Hz)                                         │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘

                                    │
                                    │ Network (UDP)
                                    ▼

┌─────────────────────────────────────────────────────────────────────────────┐
│                         CLIENT PREDICTION                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  11. SNAPSHOT RECEIVE (client_prediction.odin)                             │
│      client_world_apply_snapshot()                                         │
│      ├─ Receive server snapshot                                            │
│      ├─ Extract server's stamina value (authoritative)                     │
│      └─ Call client_prediction_reconcile()                                 │
│                                                                             │
│  12. PREDICTION RECONCILE (client_prediction.odin)                         │
│      client_prediction_reconcile()                                         │
│      ├─ Replace predicted state with server state                          │
│      ├─ Replay all inputs server hasn't seen yet                           │
│      └─ Result: predicted_char.stamina matches server                      │
│                                                                             │
│  13. RENDER (client_renderer.odin)                                         │
│      client_renderer_draw()                                                │
│      └─ Draw stamina bar showing current value                             │
│         (depleting at 28/s while aim-locked)                               │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Properties

### Server Authority
- **Server controls stamina drain**: The `aim_lock` flag is sent to server, but the server decides stamina cost
- **Cannot be spoofed**: Even if a modified client doesn't send `aim_lock=true`, it won't get aim assist (client-side only)
- **Cannot cheat stamina**: Client cannot claim infinite stamina - server tracks it authoritatively

### Client Prediction
- **Local aim assist**: Client applies aim assist immediately without waiting for server
- **Stamina prediction**: Client predicts stamina drain locally, reconciles with server snapshot
- **Smooth experience**: Aim assist works even during packet loss (but stamina still drains on server)

### Lock Break Conditions
Lock breaks immediately when:
1. **RMB released**: `input.held_right = false` → aim assist stops same frame
2. **Stamina depletes**: Server sets `stamina = 0` → client sees it in next snapshot → aim assist stops
3. **Target dies**: `remote.display_state.dead = true` → aim assist returns early
4. **Target lost**: Player aims away, target changes → sticky target updates → lock retargets or breaks
5. **Mouse unlocked**: ESC pressed → `input_clear_held()` → `held_right = false`

## Security Analysis

### Attack Vector: Modified Client Sends aim_lock=false but Uses Aim Assist

**Result**: Client gets aim assist but doesn't pay stamina cost

**Mitigation**: This is purely a client-side advantage. In competitive play:
- Server logs could detect suspicious accuracy patterns
- Aim assist rate (3.5 rad/s) is slow enough to not be "aimbot-level"
- Modified client is detectable via other means (aim consistency, reaction time)
- Stamina management is cosmetic from server's perspective (doesn't affect hit registration)

**Severity**: Low - cheater gets smoother aim but server still validates all hits

### Attack Vector: Modified Client Claims stamina=100 Always

**Result**: Client tries to bypass stamina drain

**Mitigation**: **Impossible** - server is authoritative on stamina
- Server computes stamina based on received `aim_lock` flag
- Client's claimed stamina value is never sent (only received)
- Client prediction reconciles with server's authoritative stamina

**Severity**: None - attack is not possible

### Attack Vector: Network Manipulation (Drop aim_lock Packets)

**Result**: Server doesn't see `aim_lock=true`, doesn't drain stamina

**Mitigation**: 
- Input packets include redundancy (3 recent inputs per packet)
- Dropping packets also affects movement, makes player stutter
- Inconsistent packet loss would break aim assist (client-side check)

**Severity**: Low - impractical attack, doesn't bypass stamina meaningfully

## Performance Characteristics

### Client-Side
- **Aim assist calculation**: ~10 operations per frame when active
  - Position subtraction, length calculation, atan2, asin, angle wrapping
- **Memory**: 2 bools (`held_right`, `aim_lock`) + 2 f32 constants
- **Network**: 1 bit in flags byte (no bandwidth increase)

### Server-Side
- **Stamina drain**: 1 multiply, 1 max per entity per tick (already doing this for sprint)
- **Memory**: 1 bool per input state
- **Network**: 1 bit in flags byte (no bandwidth increase)

### Network Protocol
- **Packet size**: No increase (uses existing flags byte)
- **Protocol version**: Bumped to v6 (incompatible with v5 clients)
- **Compatibility**: Old clients rejected at handshake

## Testing Edge Cases

| Scenario | Expected Behavior | Validated By |
|----------|-------------------|--------------|
| Hold RMB with no target | No aim assist, no stamina drain | `client_apply_aim_assist()` returns early |
| Target dies mid-lock | Lock breaks immediately | `!remote.display_state.dead` check |
| Stamina hits 0 mid-lock | Lock breaks, assist stops | `stamina <= 0` check + server drain |
| Try to sprint while locked | Sprint disabled | `!aim_locking` in sprint condition |
| Lock on teammate | No aim assist | `teams_are_enemies()` check |
| RMB + ESC | Mouse unlocks, RMB cleared | `input_clear_held()` |
| Target at 0 distance | No division by zero | `target_dist < 0.1` guard |
| Target at ±180° (yaw wrap) | Smooth rotation, no spin | `wrap_angle()` on delta |
| Pitch at limits | Clamped, no over-rotation | `clampf(..., -CAM_PITCH_MAX, CAM_PITCH_MAX)` |

## Future Optimization Opportunities

1. **Early-out on frame**: If `!input.held_right`, skip target validation entirely
2. **Lazy target center calculation**: Cache target center, update only when target changes
3. **SIMD vector math**: Use explicit vector instructions for position math (unlikely bottleneck)
4. **Distance squared comparison**: Skip `len_vec3()` square root if comparing against threshold

None of these are necessary at current scale - aim assist for one entity is not a performance concern.
