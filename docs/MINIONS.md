# Minions and ore

Every 30 seconds each team gets a wave of **lane fodder**. They walk their lane toward the golden centre, suicide-rush the first enemy player or minion that comes in range, and explode on death. If a friendly tower is missing nodes, they hop onto the **nearest** one and donate a rebuild. A flattened lane tower takes about three waves to stand again. The team that has laid most of the centre when it is fully rebuilt wins.

**Ore must be carried home.** Walking over a chunk picks it up into personal carry (multi-kind, shared 100-unit cap). Entering your team's dump zone (8 m apron at the back of base) banks it to the wallet. Death drops carried ore as loose chunks, reclaimable by anyone. No instant credit, no silent bank on death: retrieval is the errand, and corpse scrambles are now ore scrambles.

Pinned in [src/minions.odin](src/minions.odin). Minions are a sidecar pool, not `Character_State`s.

## Spell interaction

Minions deliberately do not count as entities, so **targeted spells** (Call Lightning, Friendly Heal) pass them by — exactly the way they pass pylons. Only **positional** damage finds them: projectiles, splash, and beams.

**Thunderbolt** (and any future chain beam) can both hit and chain to minions. The primary ray damages the nearest hostile in front of the caster — player or minion — and the chain arcs jump to the nearest hostile within range, searching both. A wave between you and your target is genuine cover. Friendly minions never take damage.

## Four wallets

| Ore | Whose rock | What a wave spends it on |
|---|---|---|
| Ember | Ember pylons | one extra body per wave, while the stack holds 10 |
| Tide | Tide pylons | one extra body per wave, while the stack holds 10 |
| Verdant | Verdant pylons | one extra body per wave, while the stack holds 10 |
| Gold | centre pylon | one lane-holding heavy, whole stack |

Own ore and enemy ore buy different bodies. Gold is a third spend. Nothing converts between them. Coloured ore is not dumped: each wave takes `WAVE_ORE_COST` (10) of a colour and adds one body, and the rest waits. 100 ore is ten waves of one extra, then nothing.

## Own ore: one extra fodder

Bank **your** ore and the next wave includes one more lane fodder, on your own lane. That is the whole point of retrieving your own rock. You are buying one extra body, not a thicker one. The free three (`WAVE_FODDER_BASE`) still walk if the wallet is empty. Below 10, that colour adds nothing this wave.

## Enemy ore: one pusher, triangle aim

Each wave, 10 of a rival's ore summons **one** lane-offensive minion that walks the remaining rival's lane — not the team you just robbed. One per colour. A strip cannot flood a corridor; it feeds one pusher a wave until the stack drops under 10.

From Verdant (green): spend Ember (red) → the extra body attacks Tide (blue). Tide ore sends one at Ember. Same rotation for the other seat. Steal from one neighbour, hit the other.

## Gold: a heavy that holds your lane

All gold in the wallet is dumped into **one** heavy, and only while the last one is dead. Its HP scales with the dump (`HEAVY_GOLD_COST` is the 1.0x mark). It is a bodyguard for the fodder and for the pylons, not a pusher: it sits on the near tower of its own lane and swipes whatever walks into it. It does not explode.

## What drops

Only **standard lane fodder** drop ore, and only their team's ore. That is the renewable trickle: kill their wave, walk over their rock.

**Summoned minions drop nothing.** Extra pushers bought with enemy ore, and the gold heavy, are spent force. Killing them is the reward.

Players mining pylons still knock chunks out of the tower itself. That is not minion loot. It is the pylon shedding.

## Rebuild

Fodder (and only fodder) jump into a damaged friendly tower and call `tower_build`. When two friendly towers are hurt, they take the **nearest** one: chip on the far pylon must not vacuum the wave that should be saving the inner one. A tower is "hurt" below `PYLON_REBUILD_FRAC` (not a 2% graze).

A hop restores two shield nodes. Own ore does not enlarge the hop; it adds a fourth fodder that can hop as well.

Flattening a lane tower does **not** open a super-minion push. It turns that team's next waves into a repair crew for about ninety seconds. The siege is camping the stump.

## Win

Essence does not end the round. There is no clock: the round ends only when the gold tower is fully rebuilt.

While the golden pylon stands it is only the richest rock. The moment it is gone the centre is a stump every team's wave will hop. First team to have laid most of the nodes when the tower is fully rebuilt (every original node live) wins. A tie on nodes laid is a draw. Chip damage does not delay the claim.
