# Nexus Arena

Competitive first-person spell-slinger arena (Odin). Headless 60Hz server + Sokol client with prediction, Dominion capture, and projectile combat.

Three teams (Ember / Tide / Verdant) fight over seven obelisks on a three-lane map: each lane runs from a team base through a far and near objective to an open central plaza. The round ends when the golden centre is fully rebuilt; whoever laid the most of it wins. Rounds auto-reset. By default each team has 1 bot. Humans can join up to `TEAM_SIZE` per team (currently 6), and bots stay in the match alongside them.

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

On connect the client shows a team-select screen with live player counts and a name field. Type a name of up to sixteen characters and press `Enter` to finish it, then `1` / `2` / `3` to join Ember / Tide / Verdant. The field has to be finished before the number keys mean teams rather than letters, and leaving it blank gets you a `Player-NN`. You cannot join the team that currently has strictly the most players.

In a match, hold `Tab` for the scoreboard.

`NEXUS_PORT` moves both ends off the default 27015, so a second server can run beside a live one.

Headless prediction/network test (joins the least-populated team, walks around for 30 s, reports correction rate, and prints the roster and combat log it received). `NEXUS_TEST_NAME` sets the name it joins under; `NEXUS_TEST_FIGHT=1` sends it to the middle of the arena shooting, which is what exercises the scoreline and the combat log:

```powershell
.\bin\nexus_client_test.exe
```

`check.ps1` type-checks the server, client and test client without linking, which `build.ps1` cannot do while a server is holding `bin\`. `run_wire_test.ps1` builds all three into `%TEMP%` and runs a server plus two named clients against each other end to end.

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
| Hold LMB | Charge the selected spell (Thunderbolt runs for as long as it is held) |
| Release LMB | Commit the cast — it finishes charging to full power, then fires. Holding through the full wind-up still waits for the release. |
| Hold RMB | Aim lock: draw the view onto the hostile sticky target (drains stamina faster than sprinting) |
| Esc | Open menu (while playing) or unlock mouse (in lobby) |

### In-Game Menu

Pressing Esc while playing opens the game menu and releases the mouse. From the menu you can:

- **Join a team** (1/2/3): Switch to Ember, Tide, or Verdant. The same population lock applies — you cannot join the most populated team.
- **Spectate** (4): Leave your playing body and observe the match. You can look around freely but cannot cast spells or interact.
- **Resume**: Press Esc again to close the menu and return to the game (or to spectating).

Opening the menu does not drop your current charge or target unless the existing unlock path already did so.

## Combat

Most spells are charge-cast: holding LMB winds them up over their cast time. Releasing early commits the remaining wind-up — the spell still charges to full power, then fires. Holding through the full bar still waits for the release, so a shot can be timed. You can move and look freely while charging, but dying, unlocking the mouse, swapping slots or the match ending all drop the charge.

The server times the wind-up itself — the client only reports which spell it is winding — so a modified client cannot claim charge it never held, and an early release cannot fire a half-charged shot. What it is winding is in every snapshot, so a wind-up is visible on the caster as a cast orb (below) rather than being something only they know about.

Thunderbolt is the exception: it is a held beam with no wind-up, and nothing happens on release. Holding it lights a beam that draws mana every tick it does work, until it is released or the caster runs dry.

| Spell | Cast | Cooldown | Mana | Effect |
|---|---|---|---|---|
| Arcane Missile | 0.6s | 0.2s | 12 | 18 + splash |
| Arcane Orb | 1.2s | 7.0s | 40 | 55 + heavy splash |
| Friendly Heal | 1.0s | 14.0s | 40 | 50 to you and a targeted ally |
| Frost Lance | 0.9s | 4.5s | 32 | 68, pierces 4 |
| Call Lightning | 1.8s | 8.0s | 60 | 85 on the target + 40% splash in 2.5 m |
| Thunderbolt | held | 2.0s after running dry | 24/s | 55/s on the first body under the crosshair, 50% arcing to up to 2 more within 6 m |

Arcane Missile is the cheap dart you bank down a lane. The first flight is still a skill shot; a ricochet off a wall or the floor then leans 60% of the way toward the nearest living enemy within 12 m who is on the outgoing side of that surface and in the open. A wild bank still misses, and a bounce into a crate does not seek through it. It pops after three ricochets. Friendly fire is off, so it will never lean toward a teammate or the caster.

Friendly Heal is the only spell on the bar that does something for someone else: a 1.0s wind-up that restores 50 to you and, if you have a teammate under the crosshair within 18 m and in the open, to them as well. It costs 40 mana and rests for 14 s, so it is a planned mend rather than sustain you hold through a fight — half a bar each, less than one lance, and you are standing still while it winds. A heal at full health with nobody hurt in front of you is refused rather than eating the mana, so it cannot be pre-charged before a fight. Cover breaks the ally half: if they duck out of sight before it fires, you still mend yourself if you need it, and the whole cast fizzles only if nobody was missing health. Blink is still in the spell table but off the hotbar — sustain earns the third slot more than a second mobility option does.

Call Lightning is the one spell that cannot be dodged, so everything else about it is slow. It lands on the crosshair's target (below) from the sky when the wind-up completes, with the biggest mana bill and the longest charge on the bar. The wind-up needs a hostile target within 24 m to start, and it does not care about cover — you can call a bolt on someone who has just ducked behind a pillar and wait them out. When it fires does care: if the target is out of range, well off your crosshair, or out of your line of sight at that moment, the bolt fizzles and nothing is spent. Stepping behind cover before the bolt comes down is the counterplay; the caster has then spent 1.8 s for nothing.

Thunderbolt is the exception to charge-cast: there is no wind-up and nothing happens on release. Holding it lights a beam from your hand to whatever the crosshair is on, out to 20.8 m, clipped by the world, and every server tick the first hostile body on it takes damage and arcs jump from body to body behind it. It needs 10 mana to light and then drains 24 a second, so a full bar buys about four seconds of continuous fire, and a player standing in it from full health dies in 1.8 s. Running it dry rests it for two seconds, and the server, not the client, decides when it is lit: the client draws its own beam from its own crosshair for responsiveness but the damage is only ever traced on the server. It has no burst, no splash and no reach past a wall; it punishes people who stand in the open at mid range and pays nothing against someone who keeps moving between cover.

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
| Friendly Heal | soft green | a slow swell, the only orb that promises nobody harm |
| Blink | white | a flash with nowhere aimed, since nothing is thrown (off the hotbar) |

The last quarter of a wind-up runs white, so the moment before a release is unmistakable even at a range where the colour has washed out. Held beams never get that flash — there is no release to warn about — and they leave from the orb rather than from the middle of the robe. The orb lights its own caster too: a wisp charging a lance washes its own cloth and the stone under it cyan. Your own hand orb is the same object seen from the inside, so it takes the charging spell's colour and swells with it.

### Targeting

The crosshair carries a sticky soft target: the nearest living wisp or player it sweeps over, shown by name and health bar under the crosshair. It holds through aim wobble and only changes when the crosshair covers someone else, when the target dies, or when you unlock the mouse — so a spell wound up on someone stays wound up on them. Selection is slightly more forgiving than a projectile hit and reaches 100 m.

**Context-aware targeting:** The sticky target respects the selected spell. Offensive spells (Missile, Orb, Lance, Call Lightning, Thunderbolt) only stick to enemies. Heal only sticks to teammates (not yourself). Switching spells clears an invalid target or retargets under the crosshair to a valid one, so the bar stays predictable when you swap slots mid-fight.

The selected entity goes up with every input, and targeted spells land on it — after the server has re-checked, from its own state, that it is alive, on the right side, in range, roughly where the caster is looking and in the open. Friendly Heal reads it the same way for the ally half: point at the teammate you mean to keep alive and they are mended with you. Without a teammate under the crosshair it still mends you. The server trusts nothing the client picks; the client runs the same reach test only so the bar never offers a cast the server would refuse. The name under the crosshair comes from the roster (below), so it is the name its owner typed and it is the same on every screen.

Strikes are instantaneous, so there is no projectile for the client to watch vanish. The server keeps each bolt in its snapshots for a third of a second and clients deduplicate by sequence number, so one dropped packet does not lose the flash.

**Target brackets:** The sticky target is framed in the world by four corner brackets around the wisp — red for a hostile mark, green for an ally the heal will reach. The frame turns to face the eye, so it reads the same whichever way the arena is crossed, and its stroke thickens with range so a mark on the far side of the plaza is still a mark. It rides the drawn body, bob and all, and only a wisp near enough to be drawn gets one: a frame around nothing marks nothing. Nothing is drawn with no target, or once the target is down.

### Aim lock

Holding the right mouse button leans on the sticky target: the view is drawn toward it at 3.5 rad/s rather than snapped there, so what you get is tracking help, not a shot placed for you. It pulls to `strike_center`, the same point the server validates a cast against, so the crosshair settles exactly where a strike is legal.

It is paid for in legs. Aim lock empties the stamina bar at 28/s against the 24/s a sprint costs, which is about three and a half seconds from full, and it cannot be held while sprinting. Tracking therefore costs you the ability to close or break away, and the server charges for it rather than the client: the flag only goes up on the wire when the lock actually ran, and the drain happens in the shared simulation both ends step.

The lock needs a healthy bar (20) to engage but runs until the bar is dry, so it does not chatter on and off around the threshold. It ends when the button comes up, the bar empties, the target dies or stops being hostile, the player dies, or the mouse unlocks.

### Names, the scoreboard and the combat log

Every hit in the game goes through one procedure on the server, `combat_apply_damage`, and every death through one transition in `entity_tick_death_respawn`. The scoreline and the combat log both read from those two places rather than from the spells, so a new damage source is scored and logged without touching either feature, and the two can never disagree about who hit whom.

Who is playing, what they are called and how they are doing ride a **roster** packet at 2 Hz, separate from the snapshot. The snapshot is interest-managed — it carries the nearest twenty-one bodies, because that is all you can see — and names and scores are the opposite shape: you need them for players you cannot see, and they change a few times a minute rather than sixty. Putting them in the snapshot would have meant paying for every name on every body thirty times a second and cutting the number of visible bodies to afford it. In their own packet they cost about a kilobyte every half second and the snapshot keeps its bodies. It also means the scoreboard behind `Tab` is the whole match rather than your neighbours, and a name stays put when its owner steps behind a wall.

Combat events do belong in the snapshot: they are addressed to one player, they are wanted the instant they happen, and they are gone a second later. Each client is sent only the lines it is party to. Damage from the same attacker with the same spell inside a second is folded into one line whose tally climbs, named by a sequence number — without that a lit Thunderbolt would push sixty lines a second and nothing else would ever be readable. The same sequence number is how a line survives packet loss: the server replays it until it ages out, and a client that already has it updates it in place instead of printing it twice.

Names are fixed-size on the wire and in memory, never Odin strings, because a name arrives inside a receive buffer that is reused on the next packet. They are stripped to printable ASCII when they are read off the wire, since a name reaches every HUD in the match.

The snapshot and roster byte budgets are `#assert`ed against `MAX_PACKET_SIZE` from the per-record sizes in `network.odin`: adding a field to a replicated record breaks the build rather than silently truncating packets in the first crowded fight.

## Rendering

The client is a single fullscreen fragment shader (`shaders/scene.glsl`) that ray-traces the whole scene analytically: boxes for the arena, quadrics for everything else. There is no mesh pipeline. `build.ps1` regenerates `src/scene.odin` from the shader whenever it is newer.

Other players are wisps: a hooded robe with nothing inside it but light, and three motes orbiting it. The hood is an ellipsoid leaned back so its peak droops behind, with an opening cut toward the front; through it is the dark lining and a face - two eyes and a smile - drawn as light on a disc, which is also where the wisp's light comes from. The body is two stacked open cones, shoulder to waist to hem, with an elliptical cross-section and pleats that displace the surface so the silhouette scallops. The cloth is a two-link pendulum chain simulated on the CPU per entity in the wearer's frame (`robe_simulate`): drag from travel pushes the waist back a little and the hem more, a stop throws the body's momentum into the hem as one forward swing, ropes lift the rings as they swing out, and a swing limit stands in for the cloth meeting the body. The result does not depend on the frame rate. The shader draws the surface through those two rings with two ray-cone intersections per wisp refined onto the pleats by two Newton steps, twists the pleats between the body's yaw and a lagging hem yaw, runs ripples down them, flutters the hem edge with a travelling wave that speeds up with the wearer, and stitches team-coloured trim along the hem and the hood's rim. It is all analytic - no marching - and only evaluated for rays that pass the wisp's bounding sphere.

A wisp that is killed swells where it fell, as though the light inside were filling the cloth: over 0.40 seconds the robe and the motes orbiting it ease out to 1.8 times their size, the cloth and the face brighten, and the halo around the hood widens with them. Then it bursts. The body is gone in one frame and what was inside it is thrown wide - a sphere of the team's colour with a white core, blooming from the point the face was lighting a moment before and out in 0.12 seconds, flaring the stone underfoot as it goes. The wisp stays gone for the rest of the respawn delay and comes back with its cloth at rest, since it respawns somewhere else. The phases are timed on the CPU per wisp off the `dead` flag in the snapshot and read by the shader out of `robe_fx[i].y`, so everyone watching sees the same swell and the same burst; a wisp that died out of a client's sight, or before that client was watching it, stays gone rather than replaying a burst nobody saw. A player never draws their own robe, so their own death still reads as it did: the screen desaturates and the respawn count runs down.

## Linux

```bash
./build.sh server
./build_graphical_client.sh
./bin/nexus_server
./bin/nexus_client
```

## Deploy (primord.io)

Builds both binaries locally, uploads one archive, then on the VPS installs the Linux dedicated server and publishes the Windows client for download. The VPS does not compile.

- **Linux server** via WSL → `/opt/nexus-arena/nexus_server` + systemd
- **Windows client** via `build.ps1 -Target client -Release` → `/downloads/nexus_client.exe` (under the site document root when present)

Needs WSL with `gcc` or `clang` for the server build.

```powershell
.\deploy.ps1 -User root -IdentityFile $env:USERPROFILE\.ssh\id_ed25519
.\deploy.ps1 -User root -Status
.\deploy.ps1 -User root -Logs
```

Client download: `https://primord.io/downloads/nexus_client.exe`

Options: `-SkipBuild`, `-Binary` / `-ClientBinary`, `-DownloadDir` (override publish path), `-Interactive` (password auth).
