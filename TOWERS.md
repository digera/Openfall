# Tower shield-node system

Gameplay authority for the seven ore towers. Replaces the occupancy-grid
pylon: damage, collision, minion rebuild and scoring all go through
`src/tower_nodes.odin`. The client draws the same core cylinder and node
spheres the server raycasts.

## What a tower is

Each tower is a thin core plus a spiral of overlapping ore nodes.

- **Core.** Vertical cylinder, radius 0.55 m. Height is the live node column:
  floor to the current cap (`2 * node_radius + (live_count-1) * stack_step`).
  Derived, not synced. Last stand in the gaps once the shell is thin, not a
  fat pillar that swallows beams.
- **Nodes.** 24 / 12 / 12 for gold / near-lane / far-lane. Each has a stable
  `Node_ID`, HP, and an alive flag. Identity is the ID, never the spiral slot.
  Radius is a fraction of the full-tower pitch, not the old hex circumradius,
  so a node is one course of the pylon rather than a boulder through the floor.
- **Spiral.** Rank 0 is the highest-HP live node and sits on the floor (centre
  at `node_radius`). The last live rank kisses the cap. Position is a golden-
  angle helix wrapped on the core. Destroying a node shortens core and shell
  together by one course; rebuild grows them the same way, floor to ceiling.

The client draws that geometry analytically: one cylinder and one sphere per
live node, the same primitives the server raycasts. There is no occupancy
atlas. Hits address the Node_ID found at the impact point. After the bite, live
nodes re-sort by `hp DESC, Node_ID ASC`. A later bite at the same aim may
find a different node in that slot; the bite that just happened cannot hop.

## Damage

Beams and blasts raycast analytically (sphere per live node, cylinder for the
core). Splash collects overlapping nodes first, then applies damage by array
index, then re-sorts. Fractional HP counts: a 0.60 bite must yield ore and
dirty the wire, not truncate to zero.

Ore pays out as a fraction of the node's HP removed, so chipping sheds rock
before the node dies. Gold toughness still divides incoming amount.

A projectile that stops a hair short of the surface snaps to the nearest live
node inside a short fallback, so side hits and core grazes still carve.

## Minion rebuild

One hop restores `TOWER_DONATE_BASE` (2) nodes, plus up to
`TOWER_DONATE_OWN_EXTRA` (2) from the wave's own-ore bolster. Three unbuffed
fodder over three waves put back 6, which is half of a 12-node lane tower.
A team that has been banking its own ore can do it in one or two waves; a
jackpot still cannot rebuild the whole tower in a single hop.

Centre scoring still counts donated nodes. First team to have laid most of
the gold silhouette when it closes (`CENTRE_CLAIM_FRAC`) wins.

## Wire (protocol v14)

Quantized node HP, 32 bytes per tower, 0 = dead. Alive nodes never pack as 0
(minimum 1) so a sliver of HP does not look dead on the client. Unused slots
on smaller towers are zero. Snapshot still carries at most two dirty towers;
GameState carries all seven. `SNAPSHOT_WORST_BYTES` stays under MTU.

The client unpacks HP, re-sorts locally, and rebuilds the spiral. Collision
and drawing on the client use the same node spheres as the server.

## Damage visualization

Drawing matches collision: every live node is the full sphere, dead nodes are
omitted, core height matches the live column (floor to cap). Chip damage is a
**scar** stamped at the bite (the outward face of the node that just lost HP).
The scar survives the re-sort, so the beam's impact powders and lights up even
as that node climbs the spiral. Repeated bites on the same face merge into one
growing scar.

Lane light, apron dust, and the HUD use **mass** (`sum(hp) / sum(max_hp)`),
not `intact`. `intact` is still `live_count / max_count` for scoring and
minion rebuild. Lighting and the percent readout therefore move on the
first chip, not the first kill.

`g_pylons` / `Pylon_World` in `pylons.odin` are unused leftovers from the
occupancy-grid era. Gameplay authority is `g_towers`.

## Out of scope

Smooth node morphing between ranks, a custom node mesh, and bot pathing that
aims at a specific low-HP node. Those can follow without changing the
authority.
