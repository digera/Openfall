# SFX

1999-era one-shot synths for Nexus Arena. Graphs are authored in the Wirebang dialect (oscillator, noise, filter, gain, shaper, panner, delay) and Live-exported to Odin.

Each generated `*.odin` file is a self-contained `play_*` procedure plus the Wirebang DSP helpers. The game does not import Wirebang at runtime; it owns a miniaudio engine and calls `play_cue`.

Charge and beam "loops" are overlapping one-shot grains retriggered by `src/client_audio.odin`.

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

## Regenerate

From the repo root, with Wirebang checked out locally:

```
odin run tools/gen_sfx -collection:wb=C:\Users\lusr\wirebang-odin
```

`cue.odin` is handwritten and is not overwritten.
