package sfx

import ma "vendor:miniaudio"

// Playback bank. The Wirebang scripts in this package synthesize PCM; init
// runs each one once and play_cue only copies the cached buffer into a sound.

@(private)
Bank_Clip :: struct {
	pcm: []f32,
	sr:  u32,
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
		g_clips[cue] = {pcm = g_capture, sr = g_capture_sr}
		g_capture = {}
	}
	g_ready = true
	return true
}

uninit :: proc() {
	for cue in Cue {
		delete(g_clips[cue].pcm)
		g_clips[cue] = {}
	}
	g_ready = false
	reap_playing(true)
}

play_cue :: proc(engine: ^ma.engine, cue: Cue) {
	if engine == nil || !g_ready {
		return
	}
	clip := g_clips[cue]
	if len(clip.pcm) < 2 {
		return
	}
	submit_pcm(engine, clip.pcm, clip.sr)
}

MAX_PLAYING :: 32

@(private)
Playing :: struct {
	used:   bool,
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
	reap_playing()
	slot: ^Playing
	for &s in g_playing {
		if !s.used {
			slot = &s
			break
		}
	}
	if slot == nil {
		slot = &g_playing[0]
		ma.sound_uninit(&slot.sound)
		ma.audio_buffer_uninit(&slot.buffer)
		slot.used = false
	}
	nframes := u64(len(frames) / 2)
	cfg := ma.audio_buffer_config_init(.f32, 2, nframes, raw_data(frames), nil)
	cfg.sampleRate = sr
	if ma.audio_buffer_init_copy(&cfg, &slot.buffer) != .SUCCESS {
		return
	}
	flags := ma.sound_flags{.NO_PITCH, .NO_SPATIALIZATION}
	if ma.sound_init_from_data_source(engine, cast(^ma.data_source)&slot.buffer, flags, nil, &slot.sound) != .SUCCESS {
		ma.audio_buffer_uninit(&slot.buffer)
		return
	}
	if ma.sound_start(&slot.sound) != .SUCCESS {
		ma.sound_uninit(&slot.sound)
		ma.audio_buffer_uninit(&slot.buffer)
		return
	}
	slot.used = true
}
