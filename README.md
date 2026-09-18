# Nexus Arena

Competitive first-person spell-slinger arena (Odin). Headless 60Hz server + Sokol client with prediction, Dominion capture, and projectile combat.

Three teams (Ember / Tide / Verdant) fight over seven obelisks on a three-lane map: each lane runs from a team base through a far and near objective to an open central plaza. The centre obelisk is worth double essence. First team to 1500 essence (or the leader at 12 minutes) wins the round; rounds auto-reset. By default each team has 1 bot. Humans can join up to `TEAM_SIZE` per team (currently 6), and bots stay in the match alongside them.

## Requirements (Windows)

- [Odin](https://odin-lang.org/) (dev-2026-07 or newer)
- Visual Studio 2022/2026 x64 toolchain (sokol C libs)
- `sokol-shdc`

This machine:

| Tool | Path |
|---|---|
| Odin | `C:\Users\lusr\tools\odin\odin.exe` |
| sokol-shdc | `C:\Users\lusr\tools\sokol-shdc\sokol-shdc.exe` |

`third_party/sokol-odin` is gitignored. First-time D3D11 libs: `third_party\build_sokol_d3d11.cmd` from an x64 VS prompt (or use the existing yearning copy).

## Build

```powershell
.\build.ps1                 # server + graphical client
.\build.ps1 -Target server
.\build.ps1 -Target client
.\build.ps1 -Release
```

Output:

- `bin\nexus_server.exe` (Windows dedicated server)
- `bin\nexus_client.exe`

## Playtest

The graphical client defaults to `primord.io:27015`. Launch it after the dedicated server is up on that host:

```powershell
.\bin\nexus_client.exe
```

Local dedicated server (this machine):

```powershell
.\bin\nexus_server.exe
$env:SERVER_IP = "127.0.0.1"
.\bin\nexus_client.exe
```

On connect the client shows a team-select screen with live player counts. Press `1` / `2` / `3` to join Ember / Tide / Verdant. You cannot join the team that currently has strictly the most players.

Headless prediction/network test (joins the least-populated team, walks around for 30 s, reports correction rate):

```powershell
.\bin\nexus_client_test.exe
```

## Configuration

Server tuning knobs (environment variables):

- `BOTS_PER_TEAM`: bots spawned per team (default: 1, range: 0–6)
- `NEXUS_TEST_ESSENCE`: win threshold for testing (default: 1500)
- `NEXUS_TEST_FAST`: essence income multiplier for faster testing (default: 1)

Build flags: `-define:NEXUS_VERBOSE=true` for combat logs, `-define:NEXUS_BOT_DEBUG=true` for bot positions in the stats line.

Example with more bots for testing:

```powershell
$env:BOTS_PER_TEAM = "3"
.\bin\nexus_server.exe
```

## Controls

| Input | Effect |
|---|---|
| Click | Lock mouse |
| Mouse | Look |
| WASD | Walk |
| Shift | Sprint (drains stamina) |
| Space | Jump |
| 1–6 | Select spell (Missile / Orb / Heal / Lance / Bolt / Thunder) |
| Hold LMB | Charge the selected spell (Heal and Thunderbolt run for as long as they are held) |
| Release LMB | Cast at the charge reached |
| Esc | Unlock mouse |

## Combat

Most spells are charge-cast: holding LMB winds them up over their cast time and releasing throws them; damage scales linearly with how far the wind-up got. Releasing under 20% fizzles, so tapping is not a substitute for committing to a cast. You can move and look freely while charging, but dying, unlocking the mouse, swapping slots or the match ending all drop the charge.

The server times the wind-up itself — the client only reports which spell it is holding — so a modified client cannot claim charge it never held. What it is holding is in every snapshot, so a wind-up is visible on the caster as a cast orb (below) rather than being something only they know about.

Thunderbolt and Friendly Heal are the exceptions: they are held beams with no wind-up, and nothing happens on release. Holding one lights a beam that draws mana every tick it does work, until it is released or the caster runs dry.

| Spell | Cast | Cooldown | Mana | Effect |
|---|---|---|---|---|
| Arcane Missile | 0.6s | 1.2s | 12 | 18 + splash |
| Arcane Orb | 1.2s | 7.0s | 40 | 55 + heavy splash |
| Friendly Heal | held | 3.0s after running dry | 20/s while mending | 30 health/s to an ally in a wide 18 m cone, or to yourself |
| Frost Lance | 0.9s | 4.5s | 32 | 68, pierces 4 |
| Call Lightning | 1.8s | 8.0s | 60 | 85 on the target + 40% splash in 2.5 m |
| Thunderbolt | held | 2.0s after running dry | 24/s | 55/s on the first body under the crosshair, 50% arcing to up to 2 more within 6 m |

Friendly Heal is Thunderbolt in reverse: a held beam that mends instead of burns, and the only spell on the bar that does something for someone else. It restores 30 health a second for 20 mana a second, so a full pool buys five seconds and about 150 health — more than a full bar of mana is worth in damage, but only if there is someone to spend it on. Who it mends is decided in that order: the teammate under your crosshair, then the nearest wounded teammate inside a 60-degree cone out to 18 m, then yourself. The cone is much wider than a damage beam's because keeping a moving ally up should not be an aim test, and the beam visibly bends to whoever it picked. Cover breaks it: it only mends people it can see.

It costs nothing to hold over a healthy team. With nobody hurt in front of it the beam idles — lit, green and drawing no mana — and starts mending the tick someone needs it, so there is no way to waste a pool by holding the button. It is still sustain and not an escape: you are standing in the open, lit up green, doing no damage while it runs, so trading into a healing opponent wins. Blink is still in the spell table but off the hotbar — sustain earns the third slot more than a second mobility option does.

Call Lightning is the one spell that cannot be dodged, so everything else about it is slow. It lands on the crosshair's target (below) the moment you release, from the sky, with the biggest mana bill and the longest wind-up on the bar. The wind-up needs a hostile target within 24 m to start, and it does not care about cover — you can call a bolt on someone who has just ducked behind a pillar and wait them out. The *release* does care: if the target is out of range, well off your crosshair, or out of your line of sight at that moment, the bolt fizzles and nothing is spent. Stepping behind cover before the bolt comes down is the counterplay; the caster has then spent 1.8 s for nothing.

Thunderbolt is the exception to charge-cast: there is no wind-up and nothing happens on release. Holding it lights a beam from your hand to whatever the crosshair is on, out to 26 m, clipped by the world, and every server tick the first hostile body on it takes damage and arcs jump from body to body behind it. It needs 10 mana to light and then drains 24 a second, so a full bar buys about four seconds of continuous fire, and a player standing in it from full health dies in 1.8 s. Running it dry rests it for two seconds, and the server, not the client, decides when it is lit: the client draws its own beam from its own crosshair for responsiveness but the damage is only ever traced on the server. It has no burst, no splash and no reach past a wall; it punishes people who stand in the open at mid range and pays nothing against someone who keeps moving between cover.

### Cast orbs

Every wisp winding a spell up holds an orb out along its aim, and the orb is the whole telegraph: its colour names the spell, its size and heat say how far the wind-up has come, and where it points is where the spell is going. A cast is answerable because of it — an opponent who can read "heavy indigo orb, nearly full, pointed at me" has time to break line of sight, and the wind-up is only counterplay if it can be seen. It is server-authoritative like the cast it warns about, so no client can hide a charge, and it is drawn on bots exactly as it is on players.

The shape of each tell is the shape of what is about to happen, so the spell is readable before the colour is:

| Spell | Orb | Tell |
|---|---|---|
| Arcane Missile | small, violet | a short dart along the aim, stuttering 14 times a second |
| Arcane Orb | large, indigo | the lob it will fly, sagging under its own weight, and a slow heavy swell |
| Frost Lance | cyan, tapered | the charge draws out into the spear it becomes, dead straight and the longest reach on the bar |
| Call Lightning | white-blue | a crackling column climbing to the sky the bolt falls out of, plus the line to whose head it lands on |
| Thunderbolt | electric blue | crackles in place for as long as the beam pouring out of it is lit |
| Friendly Heal | soft green | breathes rather than crackling, the only orb that promises nobody harm |
| Blink | white | a flash with nowhere aimed, since nothing is thrown (off the hotbar) |

The last quarter of a wind-up runs white, so the moment before a release is unmistakable even at a range where the colour has washed out. Held beams never get that flash — there is no release to warn about — and they leave from the orb rather than from the middle of the robe. The orb lights its own caster too: a wisp charging a lance washes its own cloth and the stone under it cyan. Your own hand orb is the same object seen from the inside, so it takes the charging spell's colour and swells with it.

### Targeting

The crosshair carries a sticky soft target: the nearest living wisp or player it sweeps over, shown by name and health bar under the crosshair. It holds through aim wobble and only changes when the crosshair covers someone else, when the target dies, or when you unlock the mouse — so a spell wound up on someone stays wound up on them. Selection is slightly more forgiving than a projectile hit and reaches 100 m.

**Context-aware targeting:** The sticky target respects the selected spell. Offensive spells (Missile, Orb, Lance, Call Lightning, Thunderbolt) only stick to enemies. Heal only sticks to teammates (not yourself). Switching spells clears an invalid target or retargets under the crosshair to a valid one, so the bar stays predictable when you swap slots mid-fight.

The selected entity goes up with every input, and targeted spells land on it — after the server has re-checked, from its own state, that it is alive, on the right side, in range, roughly where the caster is looking and in the open. The heal beam reads it the same way: point at the teammate you mean to keep alive and the beam follows them rather than whoever happens to be nearest. The server trusts nothing the client picks; the client runs the same reach test only so the bar never offers a cast the server would refuse. Target names are derived from the entity id on both ends rather than replicated, so they cost nothing per snapshot and cannot disagree between clients.

Strikes are instantaneous, so there is no projectile for the client to watch vanish. The server keeps each bolt in its snapshots for a third of a second and clients deduplicate by sequence number, so one dropped packet does not lose the flash.

## Rendering

The client is a single fullscreen fragment shader (`shaders/scene.glsl`) that ray-traces the whole scene analytically: boxes for the arena, quadrics for everything else. There is no mesh pipeline. `build.ps1` regenerates `src/scene.odin` from the shader whenever it is newer.

Other players are wisps: a hooded robe with nothing inside it but light, and three motes orbiting it. The hood is an ellipsoid leaned back so its peak droops behind, with an opening cut toward the front; through it is the dark lining and a face - two eyes and a smile - drawn as light on a disc, which is also where the wisp's light comes from. The body is two stacked open cones, shoulder to waist to hem, with an elliptical cross-section and pleats that displace the surface so the silhouette scallops. The cloth is a two-link pendulum chain simulated on the CPU per entity in the wearer's frame (`robe_simulate`): drag from travel pushes the waist back a little and the hem more, a stop throws the body's momentum into the hem as one forward swing, ropes lift the rings as they swing out, and a swing limit stands in for the cloth meeting the body. The result does not depend on the frame rate. The shader draws the surface through those two rings with two ray-cone intersections per wisp refined onto the pleats by two Newton steps, twists the pleats between the body's yaw and a lagging hem yaw, runs ripples down them, flutters the hem edge with a travelling wave that speeds up with the wearer, and stitches team-coloured trim along the hem and the hood's rim. It is all analytic - no marching - and only evaluated for rays that pass the wisp's bounding sphere.

## Linux

```bash
./build.sh server
./build_graphical_client.sh
./bin/nexus_server
./bin/nexus_client
```
