// Measures what the spatializer actually does to a cue, with no audio device
// and no ears: an engine in noDevice mode is read straight into a buffer and
// the per-channel RMS of one placed cue is printed. It is here because the
// axis convention in sfx.set_listener is a claim about miniaudio's internal
// cross products that is otherwise only checkable by listening.
//
//   odin run tools/check_sfx_space -collection:game=.
package main

import "core:fmt"
import "core:math"
import ma "vendor:miniaudio"
import sfx "game:sfx"

SR     :: 48000
FRAMES :: SR // one second, longer than any cue

// One placed cue, drained to the end, as RMS per channel.
measure :: proc(eng: ^ma.engine, buf: []f32, cue: sfx.Cue, em: sfx.Emitter) -> (l, r: f32) {
	sfx.play_cue_at(eng, cue, em)
	read: u64
	ma.engine_read_pcm_frames(eng, raw_data(buf), u64(len(buf) / 2), &read)
	if read == 0 {
		return
	}
	for i in 0 ..< int(read) {
		l += buf[i * 2] * buf[i * 2]
		r += buf[i * 2 + 1] * buf[i * 2 + 1]
	}
	return math.sqrt(l / f32(read)), math.sqrt(r / f32(read))
}

main :: proc() {
	cfg := ma.engine_config_init()
	cfg.noDevice = true
	cfg.channels = 2
	cfg.sampleRate = SR
	eng: ma.engine
	if ma.engine_init(&cfg, &eng) != .SUCCESS {
		fmt.eprintln("engine init failed")
		return
	}
	defer ma.engine_uninit(&eng)

	if !sfx.init(&eng) {
		fmt.eprintln("sfx init failed")
		return
	}
	defer sfx.uninit()

	buf := make([]f32, FRAMES * 2)
	defer delete(buf)

	// The listener as the client sets it from the camera: at the origin,
	// looking down +X, +Z up. camera_right(yaw = 0) is -Y, so +Y is the left
	// ear and -Y the right one.
	sfx.set_listener(&eng, {0, 0, 0}, {1, 0, 0}, {0, 0, 1})

	mid := sfx.Emitter{min_dist = 5, max_dist = 80, rolloff = 1, volume = 1}

	fmt.println("Missile_Cast, Mid falloff (min 5 m, rolloff 1)")
	fmt.println("where                      left      right")
	cases := []struct {
		name: string,
		pos:  [3]f32,
	} {
		{"10 m left  (+Y)",   {0, 10, 0}},
		{"10 m right (-Y)",   {0, -10, 0}},
		{"10 m ahead (+X)",   {10, 0, 0}},
		{"10 m behind (-X)",  {-10, 0, 0}},
		{"10 m above (+Z)",   {0, 0, 10}},
		{"3 m ahead",         {3, 0, 0}},
		{"40 m ahead",        {40, 0, 0}},
		{"75 m ahead",        {75, 0, 0}},
	}
	for c in cases {
		em := mid
		em.pos = c.pos
		l, r := measure(&eng, buf, .Missile_Cast, em)
		fmt.printf("%-22s %9.5f %10.5f\n", c.name, l, r)
	}

	em := mid
	em.pos = {200, 0, 0}
	l, r := measure(&eng, buf, .Missile_Cast, em)
	fmt.printf("%-22s %9.5f %10.5f  (culled, expect silence)\n", "200 m ahead", l, r)
}
