# Nexus Arena

Competitive first-person spell-slinger arena (Odin). Headless 60Hz server + Sokol client with prediction, Dominion capture, and projectile combat.

Three teams (Ember / Tide / Verdant) fight over four obelisks on a three-lane map: each lane runs from a team base to an open central plaza. The centre obelisk is worth double essence. First team to 1500 essence (or the leader at 12 minutes) wins the round; rounds auto-reset. Teams are filled with bots up to `TEAM_SIZE`, and bots leave as humans join.

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

- `bin\nexus_server.exe`
- `bin\nexus_client.exe`

## Playtest

Start the server, then the client (two terminals):

```powershell
.\bin\nexus_server.exe
.\bin\nexus_client.exe
```

Remote host: `$env:SERVER_IP = "192.168.x.x"` before launching the client. Default is `127.0.0.1:27015`.

On connect the client shows a team-select screen with live player counts. Press `1` / `2` / `3` to join Ember / Tide / Verdant. You cannot join the team that currently has strictly the most players.

Headless prediction/network test (joins the least-populated team, walks around for 30 s, reports correction rate):

```powershell
.\bin\nexus_client_test.exe
```

Server tuning knobs (environment variables, for testing): `NEXUS_TEST_ESSENCE=50` sets the win threshold, `NEXUS_TEST_FAST=10` multiplies essence income. Build flags: `-define:NEXUS_VERBOSE=true` for combat logs, `-define:NEXUS_BOT_DEBUG=true` for bot positions in the stats line.

## Controls

| Input | Effect |
|---|---|
| Click | Lock mouse |
| Mouse | Look |
| WASD | Walk |
| Shift | Sprint (drains stamina) |
| Space | Jump |
| 1–4 | Select spell (Missile / Orb / Blink / Frost Shard) |
| Hold LMB | Cast selected spell |
| Esc | Unlock mouse |

## Linux

```bash
./build.sh server
./build_graphical_client.sh
./bin/nexus_server
./bin/nexus_client
```
