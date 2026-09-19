# Tower shield-node system

Gameplay authority for the seven ore towers. Replaces the occupancy-grid
pylon: damage, collision, minion rebuild and scoring all go through
`src/tower_nodes.odin`. The client draws the same core cylinder and node
spheres the server raycasts.

## What a tower is

Each tower is a thin core plus a spiral of overlapping ore nodes.

- **Core.** Vertical cylinder, radius 0.55 m. Height covers the highest
  occupied slot (`tower_column_height(highest_live + 1)`), so a live cap
  stays inside the bound and a packed collapse actually shortens the tower.
  Flattened towers drop the core and stop blocking. Derived, not synced.
  Thin on purpose: it does not swallow beams the way a fat pillar would.
- **Nodes.** 24 / 12 / 12 for gold / near-lane / far-lane. Each has a stable
  `Node_ID`, HP, and an alive flag. Identity for damage is the ID. Spatial
  slot is the array index. Radius is a fraction of the full-tower pitch, not
  the old hex circumradius, so a node is one course of the pylon rather than
  a boulder through the floor.
- **Spiral.** Node position is a function of array index, not HP rank.
  Slot 0 sits on the floor (centre at `node_radius`); the last slot kisses
  the cap. Position is a golden-angle helix wrapped on the core. Damage and
  death omit a sphere; they do not move neighbours. Rebuild fills the first
  dead slot (the same world point it died at, until a collapse packs the
  column and that first dead slot is the new cap).

The client draws that geometry analytically: one cylinder and one sphere per
live slot, the same primitives the server raycasts. There is no occupancy
atlas. Hits address the Node_ID found at the impact point. After the bite,
live nodes re-sort by `hp DESC, Node_ID ASC` for bookkeeping only. The
re-sort does not move geometry. A later bite at the same world point finds
the same node, or a hole if it died.

## Damage

Beams and blasts raycast analytically (sphere per live node, cylinder for the
core). Splash collects overlapping nodes first, then applies damage by array
index, then re-sorts. Fractional HP counts: a 0.60 bite must dirty the wire
and stamp a scar, not truncate to zero.

**Ore payout is 1:1 with node death.** One node killed yields one ore chunk
carrying that node's full ore (8 team / 18 gold). Chips damage HP and scar
the face for immediate feedback, but do not pay ore. Splash that kills N
nodes emits N chunks. Gold toughness still divides incoming amount.

A projectile that stops a hair short of the surface snaps to the nearest live
node inside a short fallback, so side hits and core grazes still carve.

## Collapse

Holes stay until the column is unsound. A run of **three or more consecutive
empty slots with live rock still above them** makes the tower eligible.
Trailing empties at the cap do not count (compacting them would be a no-op;
the shaft already shortened to the highest live slot).

Every `TOWER_COLLAPSE_PERIOD` (3 s) an eligible tower rolls. Base chance is
0.40 at a 3-gap, plus 0.12 per extra empty slot, capped at 0.85. On success
live nodes pack into the lowest slots. `Node_ID` and HP ride with the node.
`live_count` and `intact` do not change. The shaft drops to the new packed
span, so the tower actually shrinks. Wounds clear; the settle is the
feedback.

Minion hops still fill the first dead slot. After a collapse that is the new
top, so a wave grows the column back up rather than patching a hole that no
longer exists.

The wire does not grow: a collapse is just HP bytes moving to lower indices.
The client notices a same-count gappy mask becoming packed and starts a
`collapse_t` settle (1 → 0 over 0.9 s). Each live node corkscrews from its
old helix slot toward its packed slot and slumps slightly toward the core at
mid-morph. That 0..1 is the morph parameter SDF welding will drive when the
analytic spheres become a deformed volume: smear along the same from-to
path instead of rigid-body interpolating the spheres.

## Ore retrieval (protocol v15)

Mining a tower spawns ore chunks on the ground. **Chunks are no longer banked
instantly on pickup.** Players must carry ore back to their team's dump zone to
credit it to the team wallet.

- **Pickup:** Walking over a settled chunk picks it up into personal carry.
  Carry is **multi-kind** with a **shared 20-unit cap** (`CARRY_CAPACITY_MAX`).
  Partial pickup: if a chunk exceeds remaining space, only the portion that fits
  is picked up; the remainder stays on the ground.
- **Movement slow:** Carrying ore slows movement linearly. At 0 units: 100% speed.
  At 20 units (full): 60% speed (`CARRY_SPEED_MIN`). Applies to walk and sprint,
  server-authoritative (affects bots and players).
- **Dump zone:** An 8 m radius apron at each team base (centered at
  `WORLD_SPAWN_R + 2.0`). Standing in your team's dump while carrying banks all
  carried ore to the team wallet. Enemy dumps do nothing.
- **Drop on death:** Carried ore spawns as loose chunks at death position,
  reclaimable by anyone. No silent bank on death.
- **Minions:** Standard lane fodder still drop ore on death (`MINION_ORE_DROP`)
  as before, which must also be retrieved.

The carry state is replicated in snapshots (per-kind array, 16 bytes = 4 × f32)
so remotes and spectators see who is hauling what. Respawn clears carry.

## Minion rebuild

One hop restores `TOWER_DONATE_BASE` (2) nodes, plus up to
`TOWER_DONATE_OWN_EXTRA` (2) from the wave's own-ore bolster. Three unbuffed
fodder over three waves put back 6, which is half of a 12-node lane tower.
A team that has been banking its own ore can do it in one or two waves; a
jackpot still cannot rebuild the whole tower in a single hop.

Centre scoring still counts donated nodes. First team to have laid most of
the gold silhouette when it closes (`CENTRE_CLAIM_FRAC`) wins.

## Wire (protocol v15)

Quantized node HP, 32 bytes per tower, 0 = dead. Alive nodes never pack as 0
(minimum 1) so a sliver of HP does not look dead on the client. Unused slots
on smaller towers are zero. Snapshot still carries at most two dirty towers;
GameState carries all seven. `SNAPSHOT_WORST_BYTES` stays under MTU.

Entity snapshots now include carry state: per-kind array (4 × f32 = 16 bytes per
entity). With 15 entities max, snapshot overhead is ~240 bytes. Byte budget
updated: `SNAPSHOT_ENTITY_BYTES` = 56 (was 40 before carry, 45 after single-kind).

The client unpacks HP by array index. Collision and drawing use those same
slots: the GPU gets max_count, spiral radius, stack step, a 32-bit alive
mask packed as two 16-bit floats (so a full mask cannot become a NaN), and
during a settle the previous alive mask plus `collapse_t`.

## Damage visualization

Drawing matches collision: every live node is the full sphere at its current
slot, dead nodes are omitted (visible holes), and the core covers the
highest occupied slot. Chip damage is a **scar** stamped at the bite (the
outward face of the node that just lost HP). Repeated bites on the same aim
merge into one growing scar. A kill punches a hole that stays where you
aimed until a collapse packs the column.

Lane light, apron dust, and the HUD use **mass** (`sum(hp) / sum(max_hp)`),
not `intact`. `intact` is still `live_count / max_count` for scoring and
minion rebuild. Lighting and the percent readout therefore move on the
first chip, not the first kill. Collapse does not change mass or intact; it
only rearranges where that mass sits.

`g_pylons` / `Pylon_World` in `pylons.odin` are unused leftovers from the
occupancy-grid era. Gameplay authority is `g_towers`.

## Out of scope

SDF-welded collapse (the analytic corkscrew is the stand-in), a custom node
mesh, and bot pathing that aims at a specific low-HP node. Those can follow
without changing the authority.
