# Contributing to Openfall

## What this project is

**Openfall** is a server-authoritative spell arena built in Odin. The current focus is **Nexus Dominion**: three teams fighting for control of seven obelisks on a three-lane map with spell combat, tower destruction, and ore-based economy. The match ends when the golden centre tower is fully rebuilt; whoever laid most of it wins.

The vision evolves toward a larger open world. Spitball ideas.

## We're excited for PRs that:

- **Respect the simulation.** Gameplay changes that honor server authority: tuning spells, improving bot behavior, refining HUD clarity, adding VFX that telegraph what's happening. Small, focused changes that make the arena more readable or the combat more satisfying.

- **Embrace zero-assets / assets-as-code.** Shaders, SDFs, raymarched visuals, procedural generation, synthesized audio — not binary art packs as the source of truth. We want assets that can be versioned, reviewed, and rebuilt from code.

- **Build tooling for assets-as-code.** Exporters, generators, and pipelines that author visuals or audio through code. See [wirebang-odin](https://github.com/digera/wirebang-odin) for node-graph sound thinking, and `tools/gen_sfx` for in-repo sfx generation.

- **Harden the foundation.** Protocol hygiene, disconnect/reconnect handling, soak-test fixes, edge cases in the wire format. Stability work that makes the arena production-ready.

## We're not excited for / please don't:

- **Engine rewrites or "port to X."** Openfall is an Odin project using Sokol. Proposals to rewrite it in another language or engine will be closed.

- **Large binary asset drops that bypass the code pipeline.** If you have meshes or textures, consider how they could be generated or represented procedurally instead.

- **Premature MMO features while arena stabilization is the focus.** Inventory systems, guilds, persistence, sprawling open-world features — these distract from getting the core arena tight. Aether-Mesh is documented as a future direction, not a current implementation target.

- **Drive-by refactors with no playtest note.** If your change touches gameplay, include a brief note on what you tested and what changed. Refactors that improve structure or clarity are welcome, but "cleaned up some code" without context or testing makes review harder.

## Coding standards

- **Match the existing Odin style.** Follow the naming conventions, indentation, and comment patterns already in the codebase. Comments should explain *why*, not *what* — the code already says what it does.

- **Server-authoritative gameplay.** Do not invent client-side authority. The server decides what happened; the client predicts and reconciles. If your change touches game state, ensure the server remains the source of truth.

- **Keep PROTOCOL_VERSION and snapshot sizes honest.** If you add fields to replicated records, the wire format changes. Update `PROTOCOL_VERSION` and verify snapshot sizes stay under `MAX_PACKET_SIZE`. The build asserts against this — don't break it.

- **Small PRs, one concern per PR.** A spell tuning change is one PR. A new bot behavior is another. A rendering optimization is a third. Mixing unrelated changes makes review slow and risky.

- **No root junk markdown playtest notes.** Fold notes into existing docs like `TOWERS.md` or `MINIONS.md`, or put them in the PR body. Don't leave loose `playtest-notes-2026-09.md` files in the root.

- **Utmost quality.** Correctness, merge risk, and polish matter. Expect review pushback on changes that introduce bugs, break existing behavior, or leave rough edges. High standards keep the codebase maintainable.

## How to build and run

See the [README](README.md) for full build and playtest instructions. Quick summary:

**Windows:**
```powershell
.\build.ps1                 # server + client
.\bin\nexus_server.exe
.\bin\nexus_client.exe
```

**Linux:**
```bash
./build.sh server
./build_graphical_client.sh
./bin/nexus_server
./bin/nexus_client
```

The graphical client defaults to `primord.io:27015` (BDFL generously hosting a game server). For local testing, set `$env:SERVER_IP = "127.0.0.1"` (Windows) or `export SERVER_IP=127.0.0.1` (Linux).

## PR process

1. **Fork and branch.** Fork the repo and create a descriptive branch for your work.
2. **Focused diff.** Keep changes small and on-topic. One feature or fix per PR.
3. **Describe your playtest.** If your change touches gameplay, include a brief note on what you tested: "Ran 3 matches, tuned missile cooldown from 0.2s to 0.3s, felt less spammy."
4. **Link issues.** If your PR addresses an open issue, reference it in the PR body.
5. **Expect review.** High-quality feedback is part of the process. Be ready to iterate.

## Questions?

Open an issue or start a discussion. We're happy to clarify scope, direction, or help you find a good first contribution.
