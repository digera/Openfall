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
- **Spiral.** Node position is a stable function of array index (NOT HP rank),
  so damage and death do not move geometry. Nodes form a golden-angle helix
  wrapped on the core, with slot 0 on the floor (centre at `node_radius`) and
  the last slot kissing the cap. HP re-sorting is for internal bookkeeping;
  holes stay where you aimed.

The client draws that geometry analytically: one cylinder and one sphere per
live node, the same primitives the server raycasts. There is no occupancy
atlas. Hits address the Node_ID found at the impact point. After the bite, live
nodes re-sort by `hp DESC, Node_ID ASC` for internal bookkeeping only; the
re-sort does NOT move geometry. A later bite at the same world point finds
the same node (or a hole if it died), never a healthier neighbour sliding in.

## Damage

Beams and blasts raycast analytically (sphere per live node, cylinder for the
core). Splash collects overlapping nodes first, then applies damage by array
index, then re-sorts. Fractional HP counts: a 0.60 bite must dirty the wire
and show a scar, not truncate to zero.

**Ore payout is 1:1 with node death.** One node killed yields one ore chunk
(8 or 18 ore depending on the tower). Chips damage HP and stamp scars for
immediate feedback, but do NOT pay ore. This contract makes kills readable:
no ore spam from chips, and each chunk on the ground maps to one dead node.
Gold toughness still divides incoming amount.

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
omitted (visible holes in the spiral), core height matches the live column
(floor to cap). Chip damage is a **scar** stamped at the bite (the outward face
of the node that just lost HP). The scar sits at the stable node position, so
repeated bites on the same aim merge into one growing scar. Geometry never moves
due to HP changes, so a kill punches a hole that stays where you aimed.

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
