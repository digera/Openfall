# Death Animation Testing

The death animation is split between `robe_simulate` in `src/client_renderer.odin`,
which times the phases per wisp, and `shaders/scene.glsl`, which draws them. The
timing is checked by eye; the hand-off between the two halves is what this guide
is mostly for, because a wisp that is never submitted to the shader animates
perfectly and invisibly.

## Build

The shader must be recompiled, since `robe_fx[i].y` and the `DEATH_*` constants
changed:

```powershell
.\build.ps1        # regenerates src\scene.odin from shaders\scene.glsl
```

```bash
./build_graphical_client.sh
```

`.\check.ps1` type-checks all three targets without linking, which is quicker
when only the Odin side changed.

## The timeline

| Phase | Length | What happens |
| --- | --- | --- |
| Swell | 0.40 s | Robe, hood and motes ease out to 1.8x; cloth and face gain up to 1.5 additive tint; the hood's halo widens with them and the stone under the wisp lights up to 2.5x |
| Burst | 0.12 s | Body gone in one frame; a team-coloured sphere with a white core grows from 0.8 m to 2.0 m and fades as `(1 - t)²`; the ground flare peaks at 4x and falls to nothing |
| Gone | until respawn | Nothing drawn, and the wisp stops lighting anything |

At 60 fps the swell is about 23 frames and the burst about 8, so the robe's last
drawn frame is near 1.73x rather than exactly 1.8x. That is sampling, not a bug.

## What to look for

1. **A kill in plain sight.** Robe and motes swell together and brighten. The
   motes must ride outward with the cloth, not disappear inside it. The burst
   blooms from where the face was, not from the wisp's feet.
2. **Respawn.** The wisp comes back whole, at full size, with its cloth hanging
   at rest, and it is visible. An invisible respawned wisp means `death_t` was
   not cleared.
3. **A second death.** The same wisp must swell and burst again.
4. **Deaths out of sight.** Watch a wisp die, look away and back: it stays gone.
   Join a server where someone is already dead: they stay gone until they
   respawn, with no burst on the frame you first see them. A burst nobody
   watched is never replayed.
5. **A wisp killed from full health.** It must not shrink on the frame it dies -
   the server zeroes health, and the swell starts from the size everyone just
   saw, not from the smallest.
6. **Several at once.** Kill a group with Arcane Orb or Call Lightning splash;
   each wisp keeps its own timer and bursts on its own beat.
7. **Your own death.** No wisp is drawn for the local player, so this is
   unchanged: the screen desaturates and the respawn count runs down. There is
   no first-person flash.

## Load

```powershell
$env:BOTS_PER_TEAM = "5"
.\bin\nexus_server.exe
```

The burst is one more `corona` glow and one more point light, on the same budget
as an impact, so frame time should not move when several wisps go at once.

## Limits

- No sound on death.
- A wisp that drops out of the nearest sixteen mid-swell is dropped from the
  animation and stays gone, the same way distant cloth stops being simulated.
- The first frame after the burst ends is still submitted, with a flash faded to
  roughly `1e-13` of its peak. It costs one wisp slot for one frame and is not
  visible.
