# SFX

1999-era one-shot synths for Openfall. Graphs are authored in the Wirebang dialect and **shipped as Live-export Odin scripts**. At engine init the client runs each script once and caches the PCM; playing a cue is a buffer copy, not a resynthesis.

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
| `Transfer_Mana` / `Transfer_Stamina` / `Transfer_Heal` | One gulp when a transfer fires. No charge loop, no drip |
| `Lightning_*` | Call Lightning telegraph, release call, sky bolt |
| `Thunder_Loop` / `Thunder_Hit` | Thunderbolt beam grain / body contact |
| `Hit_Confirm` | You connected |
| `Hurt` / `Death` / `Kill` / `Respawn` | Local pain, unmake, kill sting, reform |
| `Fizzle` | Charge dropped under 20% or a strike/heal lost its target |
| `Land` / `Jump` | Movement |

Charge and beam "loops" are overlapping cached grains retriggered by `src/client_audio.odin`.

## Space

Every clip is cached twice: as the stereo mix the script rendered, and as a mono downmix. Which one plays is which question the sound answers.

- **Flat** (`sfx.play_cue`, stereo, no attenuation) for what happens *to* the listener: their own cast and fizzle, their pain and death, the hit they just landed, the kill sting. These have no position the player could hear them from.
- **Placed** (`sfx.play_cue_at`, mono) for what happens *in the world*: other people's casts, impacts, sky bolts, and other people's wind-ups. Mono because miniaudio pans by applying a gain per output channel, so a stereo source keeps its own width wherever it is put — only a mono source actually moves.

The listener is the camera's eye and look angles, without the view kick, set before anything plays each frame. `src/client_audio.odin` picks a falloff class per cue — `Near` for spellwork in someone's hands, `Mid` for casts and small impacts, `Far` for orbs, thunder and sky bolts — and sounds past a class's max distance are dropped rather than given a voice. The 48-voice pool steals the least valuable voice when it runs out, and a placed sound can never cut off a flat one.

Other people's wind-ups are one grain stream per caster rather than one global loop, each grain placed where its caster is that instant, so two wisps charging across the plaza from each other are two sounds in two places.

Two channels cannot tell ahead from behind, so the listener runs a 150° front cone that drops anything outside it to 0.7 gain. That is an "it is not in front of you" cue rather than a real front/back one.

`tools/check_sfx_space` measures all of this with no audio device — an engine in `noDevice` mode read straight into a buffer — and prints per-channel RMS for one cue placed around the listener:

```
odin run tools/check_sfx_space -collection:game=.
```

## Regenerate

From the repo root, with Wirebang checked out locally:

```
odin run tools/gen_sfx -collection:wb=C:\Users\lusr\wirebang-odin
```

`cue.odin` and `bank.odin` are handwritten and are not overwritten.
