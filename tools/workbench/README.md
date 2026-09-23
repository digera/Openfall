# Workbench (not yet implemented)

**Status:** stub / design documentation only. No build exists yet.

## Purpose

The Openfall workbench is planned as a master editor for hand-crafting scene and asset **parameters** that export to Odin/GLSL code. It enables designers to tune the analytic raytraced scene (positions, colors, SDF parameters, lighting) and preview changes in real time, then commit the resulting code for version control.

This is **not**:
- An in-match HUD editor
- A replacement for the Sokol client
- A mesh DCC tool (Blender substitute)
- A runtime component that links into `nexus_server` or `nexus_client`

## Planned Architecture

The workbench will be a **separate GUI application** built on [Skald](https://github.com/BuLEEto/Skald) (Odin immediate-mode GUI with Vulkan backend), orchestrating three subsystems:

1. **Skald shell**: The editor UI itself — parameter panels, asset browser, timeline controls.

2. **Sokol preview**: Spawn the existing `nexus_client` (or a headless tick variant) as a subprocess to preview scene changes. Hot-reload parameters via file watch / IPC. The workbench does **not** reimplement the raytracer in Vulkan — it delegates to the production Sokol + D3D11 path.

3. **Spall integration**: Launch fixed-scenario benchmarks and ingest Spall traces for profiling scene/shader changes. Spall is a **profiling tool**, not the UI framework.

4. **Export-only assets**: Write Odin modules (e.g. `assets/scene_config.odin`) and GLSL snippets that are diffable in PRs. Assets remain code, not binary art packs.

## Non-Goals

The workbench must **not** become:
- A second engine with its own rendering path
- A Blender-class DCC tool with mesh editing, rigging, animation
- A statically linked library vendored into game binaries
- A mandatory step in the build pipeline (it's an authoring tool, not a compiler)

## Dependencies (not yet vendored)

When implementation begins, the following will be required but are **not included in this stub**:

- [Skald](https://github.com/BuLEEto/Skald) — Odin immediate-mode GUI
- SDL3 (Skald's windowing dependency)
- Vulkan SDK (Skald's rendering backend)
- [Spall](https://gravitymoth.com/spall/) — profiler for benchmarks

**Do not vendor these yet.** This README establishes scope; vendoring and build integration will come in a future PR once the design is reviewed.

## Relationship to Existing Tools

Openfall already has offline CLI tools under `tools/`:

- `tools/gen_sfx` — Wirebang graph exporter for procedural audio
- `tools/check_sfx_space` — Spatializer test harness

The workbench follows the same pattern: a **separate, optional tool** that does not link into `nexus_server` or `nexus_client`. Game builds remain independent of workbench dependencies.

## Future Work

- [ ] Vendor Skald + dependencies after design review
- [ ] Implement parameter panels for `shaders/scene.glsl` SDF primitives
- [ ] IPC protocol for hot-reloading scene parameters into Sokol preview
- [ ] Asset export pipeline (Odin modules under `assets/`)
- [ ] Spall trace ingestion and benchmark launch UI
- [ ] File watcher for live GLSL edits

## Why Not Inside the Game?

An in-game editor would:
- Force every player to link Vulkan, SDL3, and a GUI framework for a tool they never use
- Complicate the server-authoritative netcode (what does "editing" mean in a live match?)
- Blur the line between gameplay code and authoring tools
- Tie asset formats to runtime performance constraints

By keeping the workbench as a **separate Skald application**, we:
- Keep game binaries lean
- Author assets in a safe, offline context
- Export diffable Odin/GLSL for review
- Match the existing `tools/gen_sfx` pattern: optional, offline, export-driven

## Questions?

This is a scope-lock PR. No implementation exists yet. For design questions or feedback, comment on the PR or open a discussion.
