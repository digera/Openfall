# Aether-Mesh: Player-Centric Network Scaling

**Status: Held idea — not scheduled**

This is not the next build milestone. Current work is stabilize the arena sim first. This document captures a refined scaling architecture for future discussion when we revisit seamless-world ambitions.

## Core Thesis

Static spatial shards cause border stutter and border-dancing exploits. A giant single 60 Hz world simulation does not scale by buying Threadrippers or cloning one process across cores.

Horizontal copies of today's server scale **total CCU** across many isolated arenas/shards — they do **not** create one seamless continent where thousands fight in one persistent geography.

**Aether-Mesh partitions by interaction and player-centric clusters**, with space as a secondary signal, not "no spatial partition." Boundaries exist, but they travel with players and merge/split based on who is fighting whom, rather than being invisible lines etched into the map.

## Three Layers

### 1. World Supervisor (~1–5 Hz)

The slow world: leases on static structures (keeps, gates, resource nodes), macro environment state, economy events. Persistence with Postgres and an optional in-memory lease registry.

Not responsible for per-swing arbitration. No Redis-backed millisecond ownership fights. Grants exclusive write leases to Concierges or Battlemasters and trusts them to enforce those leases until revoked.

### 2. Battlemaster (~20 Hz)

Large clashes and open-field battles. Simplified collision geometry (capsules, OBBs). Reduced fidelity to afford scale.

Capacity is order-of-magnitude **hundreds of players** if fidelity is cut hard: coarser ticks, simplified physics, lower-resolution hitboxes. Still authoritative, still server-reconciled, just not 60 Hz full-detail arena combat.

Battlemaster instances are promoted from Concierge clusters when interaction graphs indicate a large, stable fight. They dissolve back to Concierges when the battle ends and groups disperse.

### 3. Concierge (60 Hz)

Today's full-fidelity cell: the current `odinfpstemplate`-class simulation. High-tick, precise collision, full combat rules.

Capacity: **10–20 tightly interacting players**. Not hundreds. This is the existing arena sim running at production quality.

A Concierge is a **player-following bubble**, not a fixed map tile. It travels with the group it is authoritative for. When two groups collide, their Concierges negotiate a merge or a promotion to Battlemaster. When a party spreads out across the map, Concierges split and each carries a subgroup.

Many Concierges run in parallel, each authoritative for its own player cluster. They are the workhorse of the mesh.

## Diegetic Seams

Boundaries are **visible in-world**, not invisible client-stitching magic.

Example: **Aetheric Bubbles**. When you are in a Concierge, you can see a faint iridescent boundary sphere around your group. Crossing from one Concierge to another — or into a Battlemaster — triggers a short diegetic beat: an **Anchoring Surge** or brief stagger.

This masks the handoff: 100–200 ms where your inputs are queued, the old worker hands off your state to the new one, and the client fades or shimmers the boundary. You feel a hitch, but it has a world reason: you crossed an Aether boundary.

**Critical constraint:** Merges must be **rare** (hysteresis). If clusters merge and split every few seconds under fire, the stagger becomes rubber-banding with a narrative skin. The interaction graph must be sticky: prefer promoting to Battlemaster over thrashing 60 Hz handoffs mid-combat.

## Hard Contracts

These are the weight-bearing walls. Without them, the mesh is just "thread more processes" handwaving.

### 1. Single Writer

Every damageable entity (player, structure, NPC) has exactly one authoritative owner for HP and state each tick. No split-brain. No "both workers apply damage and we reconcile later."

HP is written by one Concierge, one Battlemaster, or the World Supervisor. Ownership can migrate, but during migration the entity is locked from damage until the new owner is sole writer.

### 2. Cross-Concierge Projectiles

Projectile fired from Concierge A toward a target owned by Concierge B:

- **Firer consumes ammo** and deducts mana on Concierge A when the spell is cast.
- **Hit validation and HP application** happen **only on Concierge B** (the target's owner) when the projectile message arrives.
- Or, if both groups are promoted, the **Battlemaster** validates and applies the hit.

Never both workers apply damage. One authoritative hit.

If the projectile message is lost or arrives after the target has migrated, the shot misses. No retries. Fire-and-forget with at-most-once delivery is simpler than exactly-once and matches player intuition: you can miss a moving target.

### 3. World Objects (Keeps, Gates, Resource Nodes)

Static structures that many players interact with have an **exclusive write lease** from the World Supervisor.

One Concierge or Battlemaster holds the lease for a given structure at any time. Remote workers send **idempotent mutate commands** to the lease holder (e.g., "player X dealt 50 damage to gate Y at tick T"). The lease holder applies the mutation, updates the structure's HP, and broadcasts the result.

Lease transfers are rare and orchestrated by the Supervisor. During transfer, the structure is briefly invulnerable (locked state).

### 4. Merge Hysteresis

Once a Concierge has formed around a group, it is **sticky**. Small fluctuations in the interaction graph do not immediately split or merge clusters.

Prefer **promoting to Battlemaster** over thrashing 60 Hz merges/splits when players are actively fighting. A Battlemaster can hold a large, hot battle at reduced fidelity; when the battle ends, it dissolves back to multiple Concierges as survivors scatter.

Hysteresis parameters (e.g., interaction-weight threshold + time-above-threshold) prevent chattering. Example: two groups must have sustained high interaction (proximity + damage + healing edges) for 3+ seconds before their Concierges merge.

### 5. No "Sub-Millisecond Parry" Claims

This is a **frame-accurate** system on Concierge ticks (~16 ms at 60 Hz), not a nanosecond-perfect distributed lock.

Clients do not get to claim "I parried 0.5 ms before the hit" across workers. Parries, blocks, and counters are resolved on the **single authoritative Concierge** that owns the defender. If attacker and defender are on different Concierges, the attack is a cross-worker projectile (contract 2) and parry windows are evaluated on the defender's worker when the hit message arrives.

No Redis-backed microsecond arbitration. Frame-accurate is the contract.

## Interaction Graph

The mesh partitions players by **interaction**, not just Euclidean distance.

### Edge Weights

Edges between players are weighted by:

- **Melee proximity:** Players within 3 m have strong edges.
- **Cast/LOS/projectile rate:** Firing at someone, healing someone, or maintaining line-of-sight on a target creates an edge. More shots per second = stronger edge.
- **Hard locks:** Target-lock (RMB aim assist) creates a strong edge. You are interacting with that player.
- **Party/raid affinity:** Party members have a baseline edge even at range. Raids have weaker affinity, but still prefer clustering.

The graph is **not** a fake-precise formula dump. Weights are heuristic: melee proximity = 10, projectile per second = 2, LOS per second = 0.5, party member = 5 baseline, etc. Tuned empirically, not derived from first principles.

### Clustering

Each tick (or every few seconds for the graph refresh), the mesh constructs the interaction graph and partitions it into clusters using a **threshold + hysteresis** algorithm.

- Players with total edge weight above a threshold (e.g., 20) form a cluster.
- Clusters with sustained high intra-cluster weight are assigned to one Concierge.
- Clusters that grow beyond Concierge capacity (~20 players) or exceed a total-weight threshold are promoted to a Battlemaster.
- Clusters that shrink below the threshold or disperse after a fight are dissolved, and players return to individual Concierges or merge with nearby smaller clusters.

This is **not** runtime KaHIP or METIS. No production dependency on a graph-partitioning library. Threshold + greedy agglomeration + hysteresis is enough for the product case. A research-grade partitioner can be a future optimization, not a launch dependency.

## What This Is / Isn't

### Is

- **Product architecture** for a Darkfall-shaped seamless continent with honesty about fidelity and seams.
- **Admission** that 60 Hz full-detail does not scale to 500 players in one fight. The mesh gives you 60 Hz for 10–20, 20 Hz for hundreds, and 1–5 Hz for the whole world.
- **Diegetic boundaries** instead of invisible shard lines that cause teleport-stutter when you cross them.

### Isn't

- A replacement for stabilizing the current arena sim. Arena first, mesh later.
- Proven. This is a design note, not a shipped feature.
- "Just thread more processes." The hard contracts (single writer, cross-worker projectiles, lease management, merge hysteresis) are the architecture. Without them, this is handwaving.

## Relation to Current Repo

**Concierge ≈ current headless authoritative Odin sim** + UDP interest snapshots.

The 60 Hz server in this repo (`nexus_server.exe`) is spiritually one Concierge: authoritative tick, snapshot replication, client prediction reconciliation. Aether-Mesh would run many such workers in parallel, each authoritative for a player cluster, with added handoff and cross-worker messaging.

**Phase 5 Postgres/spatial scaffolding** in this repo (currently marked NOT YET WIRED) is related to the World Supervisor persistence layer. It is **not** Aether-Mesh. It is table schema and spatial indexing for a future where the server needs to persist world state. Do not claim the repo already implements Aether-Mesh; it does not. This document is the first time the idea is written down.

## Roadmap: When We Revisit

This is **not** a 12-month build schedule. These are the checkpoints to hit after the arena sim plateaus and we decide to explore seamless-world scaling.

1. **IPC spike:** Prove two processes can exchange player state and projectile messages with acceptable latency (target: <10 ms round-trip on localhost, <30 ms across regional DCs).
2. **Ownership contract tests:** Implement single-writer enforcement for a toy entity. Prove cross-worker projectile hit validation works and never double-applies damage.
3. **One bubble-merge playtest:** Run two Concierges with 5 players each. Walk the groups toward each other. Trigger a merge (or promotion to Battlemaster). Measure hitch duration and player experience. If the seam is unacceptable, revisit diegetic masking or hysteresis tuning.
4. **World Supervisor lease prototype:** Implement exclusive write leases for one static structure (e.g., a gate). Prove remote workers can send damage commands and the lease holder applies them without split-brain.
5. **Interaction graph + clustering:** Implement edge-weight calculation and threshold-based clustering. Prove clusters form and dissolve predictably as players fight and scatter.

Each checkpoint is a spike or small vertical slice, not a month of eng. Total effort is unknown until we start. That is fine. This document is the starting point, not the plan.

---

**End of design note.**
