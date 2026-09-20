# Minions and ore

Every 30 seconds each team gets a wave of **lane fodder**. They walk their lane toward the golden centre, suicide-rush the first enemy player or minion that comes in range, and explode on death. If a friendly tower is missing nodes, they hop onto the **nearest** one and donate a rebuild. A flattened lane tower takes about three waves to stand again. The team that has laid most of the centre when it is fully rebuilt wins.

Ore is banked the instant a player walks over it. There is no personal carry, no death-drop, no trip home: the wallets are the team's, so whoever reaches the lump first has already decided where it goes. Essence is just the scoreboard; the wallets are what the wave actually reads.

Pinned in [src/minions.odin](src/minions.odin). Minions are a sidecar pool, not `Character_State`s.

## Spell interaction

Minions deliberately do not count as entities, so **targeted spells** (Call Lightning, Friendly Heal) pass them by — exactly the way they pass pylons. Only **positional** damage finds them: projectiles, splash, and beams.

**Thunderbolt** (and any future chain beam) can both hit and chain to minions. The primary ray damages the nearest hostile in front of the caster — player or minion — and the chain arcs jump to the nearest hostile within range, searching both. A wave between you and your target is genuine cover. Friendly minions never take damage.

## Four wallets

| Ore | Whose rock | What a wave spends it on |
|---|---|---|
| Ember | Ember pylons | extra pushers, or Ember's own buff |
| Tide | Tide pylons | extra pushers, or Tide's own buff |
| Verdant | Verdant pylons | extra pushers, or Verdant's own buff |
| Gold | centre pylon | one lane-holding heavy |

Own ore and enemy ore are different spends. Gold is a third spend. Nothing converts between them. Every wave dumps what it can; nothing is saved for a shop.

## Own ore: bolster the fodder

Bank **your** ore and the next wave's lane fodder come out thicker: extra HP, and a larger donation when they jump into a tower. That is the whole point of retrieving your own rock after your mobs die or after someone mines your pylons. You are not buying extra bodies. You are making the bodies you already get better at living and at putting the tower back.

The whole stack is spent. Bolster saturates (`OWN_ORE_SOFT_CAP`), so a jackpot cannot put a tower back in a single wave the way a steady three-wave habit does.

A team that never banks its own ore still gets a wave. It is just the thin default one (`WAVE_FODDER_BASE` bodies).

## Enemy ore: extra pushers, triangle aim

Each `PUSHER_ORE_COST` of a rival's ore summons **one extra lane-offensive minion** that walks the remaining rival's lane — not the team you just robbed. Capped at `WAVE_PUSHER_CAP` per rival colour, so a strip cannot flood a 9 m corridor.

From Verdant (green): spend Ember (red) → the extra bodies attack Tide (blue). Same rotation for the other two. Steal from one neighbour, hit the other. You do not pile onto a lane you already stripped.

## Gold: a heavy that holds your lane

All gold in the wallet is dumped into **one** heavy, and only while the last one is dead. Its HP scales with the dump (`HEAVY_GOLD_COST` is the 1.0x mark). It is a bodyguard for the fodder and for the pylons, not a pusher: it sits on the near tower of its own lane and swipes whatever walks into it. It does not explode.

## What drops

Only **standard lane fodder** drop ore, and only their team's ore. That is the renewable trickle: kill their wave, walk over their rock.

**Summoned minions drop nothing.** Extra pushers bought with enemy ore, and the gold heavy, are spent force. Killing them is the reward.

Players mining pylons still knock chunks out of the tower itself. That is not minion loot. It is the pylon shedding.

## Rebuild

Fodder (and only fodder) jump into a damaged friendly tower and call `tower_build`. When two friendly towers are hurt, they take the **nearest** one: chip on the far pylon must not vacuum the wave that should be saving the inner one. A tower is "hurt" below `PYLON_REBUILD_FRAC` (not a 2% graze).

An unbuffed hop restores two shield nodes. Own-ore buffs add up to two more, so a team that has been farming its own dead is the team that puts a tower back in one or two waves instead of three.

Flattening a lane tower does **not** open a super-minion push. It turns that team's next waves into a repair crew for about ninety seconds. The siege is camping the stump.

## Win

Essence does not end the round. The clock (12 minutes) is the backstop: highest essence, or a draw.

While the golden pylon stands it is only the richest rock. The moment it is gone the centre is a stump every team's wave will hop. First team to have laid most of the nodes when the tower is fully rebuilt (every original node live) wins. A tie on nodes laid is a draw. Chip damage does not delay the claim.
