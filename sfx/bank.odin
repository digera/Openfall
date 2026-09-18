package sfx

import "core:math"
import ma "vendor:miniaudio"

// Playback bank. The Wirebang scripts in this package synthesize PCM; init
// runs each one once and play_cue only copies the cached buffer into a sound.
//
// Every clip is cached twice. The stereo mix the script rendered is what plays
// for sounds that happen to the listener rather than somewhere in the world -
// their own cast, their own pain - and a mono downmix is what plays for the
// rest. miniaudio pans by applying a gain per output channel, so a stereo
// source keeps its own width no matter where it is put: only a mono source
// actually moves.

@(private)
Bank_Clip :: struct {
	stereo: []f32,
	mono:   []f32,
	sr:     u32,
}

// A sound somewhere in the world. `min_dist` is the radius inside which it
// plays at full volume, `rolloff` how fast it fades outside that, and
// `max_dist` where it stops being worth a voice at all.
Emitter :: struct {
	pos:      [3]f32,
	min_dist: f32,
	max_dist: f32,
	rolloff:  f32,
	volume:   f32,
}

@(private)
g_clips: [Cue]Bank_Clip
g_ready: bool
g_capturing: bool
g_capture: []f32
g_capture_sr: u32

init :: proc(engine: ^ma.engine) -> bool {
	uninit()
	if engine == nil {
		return false
	}
	g_capturing = true
	defer {
		g_capturing = false
		delete(g_capture)
		g_capture = {}
	}

	for cue in Cue {
		play_script(engine, cue)
		if len(g_capture) < 2 {
			uninit()
			return false
		}
		g_clips[cue] = {stereo = g_capture, mono = downmix_mono(g_capture), sr = g_capture_sr}
		g_capture = {}
	}
	g_ready = true
	return true
}

uninit :: proc() {
	for cue in Cue {
		delete(g_clips[cue].stereo)
		delete(g_clips[cue].mono)
		g_clips[cue] = {}
	}
	g_ready = false
	reap_playing(true)
}

@(private)
downmix_mono :: proc(stereo: []f32) -> []f32 {
	frames := len(stereo) / 2
	mono := make([]f32, frames)
	for i in 0 ..< frames {
		mono[i] = (stereo[i * 2] + stereo[i * 2 + 1]) * 0.5
	}
	return mono
}

// Two speakers cannot tell ahead from behind. The spatializer pans by dotting
// the sound's direction against each output channel's, and a stereo pair's
// channels differ only left to right, so a sound in front and the same sound
// behind come out of the mixer identical. The listener cone is the cheap
// remedy miniaudio ships for it: gain falls off outside the front cone,
// reaching BACK_GAIN directly behind. It is not a front/back cue so much as an
// "it is not in front of you" one, which is the part that matters when the
// question is whether to turn around.
FRONT_CONE :: f32(2.618) // 150 degrees, full angle
BACK_GAIN  :: f32(0.7)

// The ear. `forward` and `up` are the camera's, in world axes: miniaudio
// crosses them for its own right vector, which with a +Z up comes out as the
// game's camera_right, so there is no axis conversion to do here.
set_listener :: proc(engine: ^ma.engine, pos, forward, up: [3]f32) {
	if engine == nil {
		return
	}
	ma.engine_listener_set_world_up(engine, 0, up.x, up.y, up.z)
	ma.engine_listener_set_direction(engine, 0, forward.x, forward.y, forward.z)
	ma.engine_listener_set_position(engine, 0, pos.x, pos.y, pos.z)
	ma.engine_listener_set_cone(engine, 0, FRONT_CONE, math.TAU, BACK_GAIN)
}

// Played on the listener: no position, full stereo, no attenuation.
play_cue :: proc(engine: ^ma.engine, cue: Cue, volume: f32 = 1) {
	if engine == nil || !g_ready || volume <= 0.001 {
		return
	}
	clip := g_clips[cue]
	if len(clip.stereo) < 2 {
		return
	}
	submit_voice(engine, clip.stereo, 2, clip.sr, volume, nil)
}

// Played where it happens. Costs nothing if it happens out of earshot.
play_cue_at :: proc(engine: ^ma.engine, cue: Cue, em: Emitter) {
	if engine == nil || !g_ready || !audible(engine, em) {
		return
	}
	clip := g_clips[cue]
	if len(clip.mono) < 1 {
		return
	}
	placed := em
	submit_voice(engine, clip.mono, 1, clip.sr, em.volume, &placed)
}

// Whether `em` is worth a voice. Inverse attenuation never reaches silence on
// its own - at `max_dist` it has bottomed out at a floor rather than gone
// quiet - so the audible radius is this test, and the floor is what decides
// how big a step cutting it there is.
audible :: proc(engine: ^ma.engine, em: Emitter) -> bool {
	if engine == nil || em.volume <= 0.001 {
		return false
	}
	reach := max(em.max_dist, em.min_dist)
	return listener_dist2(engine, em.pos) <= reach * reach
}

@(private)
listener_dist2 :: proc(engine: ^ma.engine, pos: [3]f32) -> f32 {
	lp := ma.engine_listener_get_position(engine, 0)
	d := [3]f32{pos.x - lp.x, pos.y - lp.y, pos.z - lp.z}
	return d.x * d.x + d.y * d.y + d.z * d.z
}

MAX_PLAYING :: 48

@(private)
Playing :: struct {
	used:   bool,
	score:  f32,   // how much of the mix this voice is worth keeping
	buffer: ma.audio_buffer,
	sound:  ma.sound,
}

@(private)
g_playing: [MAX_PLAYING]Playing

@(private)
reap_playing :: proc(all := false) {
	for &slot in g_playing {
		if !slot.used {
			continue
		}
		if all || bool(ma.sound_at_end(&slot.sound)) {
			ma.sound_uninit(&slot.sound)
			ma.audio_buffer_uninit(&slot.buffer)
			slot.used = false
		}
	}
}

// A free slot, or the least valuable voice playing if it is worth less than
// what is asking for it. A fight in the middle of the plaza can ask for more
// voices than there are, and a distant impact must not be able to cut off the
// hit that is landing on the listener.
@(private)
acquire :: proc(score: f32) -> ^Playing {
	reap_playing()
	worst: ^Playing
	for &slot in g_playing {
		if !slot.used {
			return &slot
		}
		if worst == nil || slot.score < worst.score {
			worst = &slot
		}
	}
	if worst == nil || worst.score >= score {
		return nil
	}
	ma.sound_uninit(&worst.sound)
	ma.audio_buffer_uninit(&worst.buffer)
	worst.used = false
	return worst
}

// What the mix would lose by dropping this voice: its own volume times the
// distance gain it will be played at. Unplaced sounds outrank every placed
// one because they are feedback the player acted on.
@(private)
voice_score :: proc(engine: ^ma.engine, em: ^Emitter) -> f32 {
	if em == nil {
		return 2
	}
	min_d := max(em.min_dist, 0.1)
	dist := math.sqrt(listener_dist2(engine, em.pos))
	return em.volume * min_d / (min_d + max(em.rolloff, 0) * max(dist - min_d, 0))
}

// Shared by the Live-export scripts (capture during init) and by play_cue
// (cached buffers after that).
submit_pcm :: proc(engine: ^ma.engine, frames: []f32, sr: u32) {
	if engine == nil || len(frames) < 2 {
		return
	}
	if g_capturing {
		delete(g_capture)
		g_capture = make([]f32, len(frames))
		copy(g_capture, frames)
		g_capture_sr = sr
		return
	}
	submit_voice(engine, frames, 2, sr, 1, nil)
}

@(private)
submit_voice :: proc(engine: ^ma.engine, frames: []f32, channels, sr: u32, volume: f32, em: ^Emitter) {
	if len(frames) < int(channels) {
		return
	}
	score := voice_score(engine, em)
	slot := acquire(score)
	if slot == nil {
		return
	}
	nframes := u64(len(frames) / int(channels))
	cfg := ma.audio_buffer_config_init(.f32, channels, nframes, raw_data(frames), nil)
	cfg.sampleRate = sr
	if ma.audio_buffer_init_copy(&cfg, &slot.buffer) != .SUCCESS {
		return
	}
	flags := ma.sound_flags{.NO_PITCH}
	if em == nil {
		flags |= {.NO_SPATIALIZATION}
	}
	if ma.sound_init_from_data_source(engine, cast(^ma.data_source)&slot.buffer, flags, nil, &slot.sound) != .SUCCESS {
		ma.audio_buffer_uninit(&slot.buffer)
		return
	}
	ma.sound_set_volume(&slot.sound, max(volume, 0))
	if em != nil {
		ma.sound_set_attenuation_model(&slot.sound, .inverse)
		ma.sound_set_min_distance(&slot.sound, max(em.min_dist, 0.1))
		ma.sound_set_max_distance(&slot.sound, max(em.max_dist, em.min_dist))
		ma.sound_set_rolloff(&slot.sound, max(em.rolloff, 0))
		// Nothing here is pitchable: the clips are cached at their own rate and
		// NO_PITCH is set, so doppler would only cost the resampler.
		ma.sound_set_doppler_factor(&slot.sound, 0)
		ma.sound_set_position(&slot.sound, em.pos.x, em.pos.y, em.pos.z)
	}
	if ma.sound_start(&slot.sound) != .SUCCESS {
		ma.sound_uninit(&slot.sound)
		ma.audio_buffer_uninit(&slot.buffer)
		return
	}
	slot.used = true
	slot.score = score
}
