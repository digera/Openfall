# Tower shield-node system

Gameplay authority for the seven ore towers. Replaces the occupancy-grid
pylon: damage, collision, minion rebuild and scoring all go through
`src/tower_nodes.odin`. The occupancy atlas the client marches is paint of
this state, not a second source of truth.

## What a tower is

Each tower is a thin core plus a spiral of overlapping ore nodes.

- **Core.** Vertical cylinder, radius 0.55 m, height = `live_count * stack_step`.
  Derived, not synced. Last stand in the gaps once the shell is thin, not a
  fat pillar that swallows beams.
- **Nodes.** 32 / 28 / 24 for gold / near-lane / far-lane. Each has a stable
  `Node_ID`, HP, and an alive flag. Identity is the ID, never the spiral slot.
- **Spiral.** Rank 0 is the highest-HP live node and sits at the bottom.
  Position is a golden-angle helix around the core, with node radius large
  enough that Fibonacci neighbours overlap into a shell rather than a string
  of beads. Outer extent stays close to the old hex circumradius so a 9 m
  lane still has a shoulder.

Hits address the Node_ID found at the impact point. After the bite, live
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
fodder over three waves put back 18 nodes, which is 75% of a 24-node far
tower -- the rebuild cutoff. A team that has been banking its own ore can do
it in one or two waves; a jackpot still cannot rebuild the whole tower in a
single hop.

Centre scoring still counts donated nodes. First team to have laid most of
the gold silhouette when it closes (`CENTRE_CLAIM_FRAC`) wins.

## Wire (protocol v14)

Quantized node HP, 32 bytes per tower, 0 = dead. Alive nodes never pack as 0
(minimum 1) so a sliver of HP does not look dead on the client. Unused slots
on smaller towers are zero. Snapshot still carries at most two dirty towers;
GameState carries all seven. `SNAPSHOT_WORST_BYTES` stays under MTU.

The client unpacks HP, re-sorts locally, and paints the occupancy atlas from
the resulting spiral. Collision on the client uses the same node spheres as
the server.

## Damage Visualization (Client Paint)

**Problem:** The original node paint used subtle radius scaling (62%–100% based
on HP) that made chip damage nearly invisible in the coarse 1m occupancy grid,
especially with heavily overlapping spiral neighbors.

**Fix (current):**
- **Aggressive radius scaling:** 100% HP = full radius, 50% HP = ~45% radius,
  25% HP = ~30% radius. Node shrinkage is now dramatic and readable.
- **Occupancy intensity modulation:** Damaged nodes paint at reduced intensity
  (100% HP = full, 50% HP = 70%, 0% HP = 40% base). This makes chips visible
  even when radius overlap hides size changes.
- **Result:** While mining, tower silhouette visibly deforms, thins, and loses
  mass. Chip damage is readable before nodes die. Node deaths create clear gaps
  in the shell.

**Authority vs Paint:**
- Server: `Tower_World` in `tower_nodes.odin` (nodes with HP, spiral position)
- Client: `tower_paint_occupancy` paints nodes → 8×8×20 occupancy atlas →
  shader marches the 0.5 iso with grain (unchanged from pylon era)
- No dual authority: `g_pylons` / `Pylon_World` gameplay instances removed;
  `pylons.odin` kept only for shared helpers (`ore_color`, `team_ore`,
  `ore_grid` structure, constants)

## Out of scope

Smooth node morphing between ranks, a custom node mesh, and bot pathing that
aims at a specific low-HP node. Those can follow without changing the
authority.
