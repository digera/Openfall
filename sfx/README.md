# SFX

1999-era one-shot synths for Nexus Arena. Graphs are authored in the Wirebang dialect and **shipped as Live-export Odin scripts**. At engine init the client runs each script once and caches the PCM; playing a cue is a buffer copy, not a resynthesis.

## Layout

| Path | What it is |
|---|---|
| `tools/gen_sfx/patches.odin` | Node graphs |
| `sfx/*.odin` (generated) | Wirebang `play_*` scripts |
| `sfx/cue.odin` / `sfx/bank.odin` | Cue list, init-time cache, playback pool |

## Cues

| Cue | Used for |
|---|---|
| `Missile_*` | Arcane Missile charge grain, zip, spark pop |
| `Orb_*` | Arcane Orb rumble, whoomp, explosion |
| `Lance_*` | Frost Lance crystal scrape, shard throw, shatter |
| `Blink_*` | Blink wind-up and arrival |
| `Heal_Loop` / `Heal_Tick` | Friendly Heal charge grain / burst |
| `Lightning_*` | Call Lightning telegraph, release call, sky bolt |
| `Thunder_Loop` / `Thunder_Hit` | Thunderbolt beam grain / body contact |
| `Hit_Confirm` | You connected |
| `Hurt` / `Death` / `Kill` / `Respawn` | Local pain, unmake, kill sting, reform |
| `Fizzle` | Charge dropped under 20% or a strike/heal lost its target |
| `Land` / `Jump` | Movement |

Charge and beam "loops" are overlapping cached grains retriggered by `src/client_audio.odin`.

## Regenerate

From the repo root, with Wirebang checked out locally:

```
odin run tools/gen_sfx -collection:wb=C:\Users\lusr\wirebang-odin
```

`cue.odin` and `bank.odin` are handwritten and are not overwritten.
