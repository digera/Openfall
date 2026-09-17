# Nexus Arena

Competitive first-person spell-slinger arena (Odin). Headless 60Hz server + Sokol client with prediction, Dominion capture, and projectile combat.

Three teams (Ember / Tide / Verdant) fight over four obelisks on a three-lane map: each lane runs from a team base to an open central plaza. The centre obelisk is worth double essence. First team to 1500 essence (or the leader at 12 minutes) wins the round; rounds auto-reset. By default, each team has 1 bot. Humans can join up to `TEAM_SIZE` per team (currently 6), and bots remain active alongside humans.

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

- `BOTS_PER_TEAM`: Number of bots spawned per team (default: 1, range: 0-6)
- `NEXUS_TEST_ESSENCE`: Win threshold for testing (default: 1500)
- `NEXUS_TEST_FAST`: Essence income multiplier for faster testing (default: 1)

Build flags: `-define:NEXUS_VERBOSE=true` for combat logs, `-define:NEXUS_BOT_DEBUG=true` for bot positions in the stats line.

Example with more bots for testing:

```bash
BOTS_PER_TEAM=3 ./bin/nexus_server
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
| Hold LMB | Charge the selected spell (Thunderbolt fires for as long as it is held) |
| Release LMB | Cast at the charge reached |
| Esc | Unlock mouse |

## Combat

Spells are charge-cast. Holding LMB winds the selected spell up over its cast time and releasing throws it; damage and healing scale linearly with how far the wind-up got. Releasing under 20% fizzles, so tapping is not a substitute for committing to a cast. You can move and look freely while charging, but dying, unlocking the mouse, swapping slots or the match ending all drop the charge.

The server times the wind-up itself — the client only reports which spell it is holding — so a modified client cannot claim charge it never held.

| Spell | Cast | Cooldown | Mana | Effect |
|---|---|---|---|---|
| Arcane Missile | 0.6s | 1.2s | 12 | 18 + splash |
| Arcane Orb | 1.2s | 7.0s | 40 | 55 + heavy splash |
| Self Heal | 1.0s | 5.0s | 30 | restores 45 to the caster |
| Frost Lance | 0.9s | 4.5s | 32 | 68, pierces 4 |
| Call Lightning | 1.8s | 8.0s | 60 | 85 on the target + 40% splash in 2.5 m |
| Thunderbolt | held | 2.0s after running dry | 24/s | 55/s on the first body under the crosshair, 50% arcing to up to 2 more within 6 m |

Self Heal is sustain, not an escape: a full wind-up is worth less than one lance, so trading into a healing opponent still wins, and a heal at full health is refused outright rather than eating the mana, so it cannot be pre-charged before a fight. Blink is still in the spell table but off the hotbar — sustain earns the third slot more than a second mobility option does.

Call Lightning is the one spell that cannot be dodged, so everything else about it is slow. It lands on the crosshair's target (below) the moment you release, from the sky, with the biggest mana bill and the longest wind-up on the bar. The wind-up needs a hostile target within 24 m to start, and it does not care about cover — you can call a bolt on someone who has just ducked behind a pillar and wait them out. The *release* does care: if the target is out of range, well off your crosshair, or out of your line of sight at that moment, the bolt fizzles and nothing is spent. Stepping behind cover before the bolt comes down is the counterplay; the caster has then spent 1.8 s for nothing.

Thunderbolt is the exception to charge-cast: there is no wind-up and nothing happens on release. Holding it lights a beam from your hand to whatever the crosshair is on, out to 26 m, clipped by the world, and every server tick the first hostile body on it takes damage and arcs jump from body to body behind it. It needs 10 mana to light and then drains 24 a second, so a full bar buys about four seconds of continuous fire, and a player standing in it from full health dies in 1.8 s. Running it dry rests it for two seconds, and the server, not the client, decides when it is lit: the client draws its own beam from its own crosshair for responsiveness but the damage is only ever traced on the server. It has no burst, no splash and no reach past a wall; it punishes people who stand in the open at mid range and pays nothing against someone who keeps moving between cover.

### Targeting

The crosshair carries a sticky soft target: the nearest living wisp or player it sweeps over, shown by name and health bar under the crosshair. It holds through aim wobble and only changes when the crosshair covers someone else, when the target dies, or when you unlock the mouse — so a spell wound up on someone stays wound up on them. Selection is slightly more forgiving than a projectile hit and reaches 100 m.

The selected entity goes up with every input, and targeted spells land on it — after the server has re-checked, from its own state, that it is alive, hostile, in range, roughly where the caster is looking and in the open. The server trusts nothing the client picks; the client runs the same reach test only so the bar never offers a cast the server would refuse. Target names are derived from the entity id on both ends rather than replicated, so they cost nothing per snapshot and cannot disagree between clients.

Strikes are instantaneous, so there is no projectile for the client to watch vanish. The server keeps each bolt in its snapshots for a third of a second and clients deduplicate by sequence number, so one dropped packet does not lose the flash.

## Linux

```bash
./build.sh server
./build_graphical_client.sh
./bin/nexus_server
./bin/nexus_client
```
