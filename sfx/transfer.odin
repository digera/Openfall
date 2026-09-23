// One-shot SFX. Lesser-magic transfers: a single gulp when the cast fires.
// The drip that follows is silent. Pitch rises into mana, falls into stamina,
// and the heal is the same gulp with one brighter tail.
package sfx

import "core:math"
import "core:math/rand"
import ma "vendor:miniaudio"

play_transfer_mana :: proc(engine: ^ma.engine) {
	play_siphon(engine, 0.30, 180, 620, 0.14, 0.28, 900, 2800, 1.6, 0.18, 0.06, 0.10, 0, 0, 0, 0)
}

play_transfer_stamina :: proc(engine: ^ma.engine) {
	play_siphon(engine, 0.30, 540, 140, 0.13, 0.28, 2200, 500, 1.4, 0.16, 0.055, 0.12, 0, 0, 0, 0)
}

play_transfer_heal :: proc(engine: ^ma.engine) {
	play_siphon(engine, 0.34, 392, 784, 0.12, 0.22, 3000, 5200, 2.2, 0.05, 0.03, 0.05, 588, 1176, 0.08, 0.16)
}

@(private="file")
play_siphon :: proc(
	engine: ^ma.engine,
	dur, tone0, tone1, tone_amp, tone_dur, noise0, noise1, noise_q, noise_ramp, noise_amp, noise_dur, tail0, tail1, tail_amp, tail_dur: f32,
) {
	if engine == nil {
		return
	}
	sr := ma.engine_get_sample_rate(engine)
	if sr == 0 {
		sr = 48000
	}
	frames := int(math.ceil_f64(f64(sr) * f64(dur)))
	out := make([]f32, frames * 2)
	defer delete(out)

	tone: ma.waveform
	tone_f0 := tone0 * (f32(0.97) + rand.float32() * f32(0.06))
	tone_f1 := max(f32(0.001), tone1 * (f32(0.97) + rand.float32() * f32(0.06)))
	tone_cfg := ma.waveform_config_init(.f32, 1, sr, .sine, 1, f64(tone_f0))
	if ma.waveform_init(&tone_cfg, &tone) != .SUCCESS {
		return
	}
	defer ma.waveform_uninit(&tone)
	tone_buf := make([]f32, frames)
	defer delete(tone_buf)
	read_waveform_ramp(&tone, tone_buf, sr, tone_f0, tone_f1, 0, tone_dur, .exp)
	tone_gain := make([]f32, frames)
	defer delete(tone_gain)
	gain_env(tone_buf, tone_gain, sr, max(f32(0.001), tone_amp), 0, tone_dur)
	add_mono_to_stereo(out, tone_gain)

	breath: ma.noise
	breath_cfg := ma.noise_config_init(.f32, 1, .white, i32(rand.uint32()), 1)
	if ma.noise_init(&breath_cfg, nil, &breath) != .SUCCESS {
		return
	}
	defer ma.noise_uninit(&breath, nil)
	breath_buf := make([]f32, frames)
	defer delete(breath_buf)
	read_noise_window(&breath, breath_buf, sr, 0, noise_dur)

	bp: ma.biquad
	bp_f0 := noise0 * (f32(0.96) + rand.float32() * f32(0.08))
	bp_f1 := max(f32(0.001), noise1 * (f32(0.96) + rand.float32() * f32(0.08)))
	if !biquad_init_rbj(&bp, sr, .bandpass, bp_f0, noise_q) {
		return
	}
	defer ma.biquad_uninit(&bp, nil)
	bp_buf := make([]f32, frames)
	defer delete(bp_buf)
	biquad_sweep(&bp, breath_buf, bp_buf, sr, .bandpass, noise_q, bp_f0, bp_f1, noise_ramp)
	breath_gain := make([]f32, frames)
	defer delete(breath_gain)
	gain_env(bp_buf, breath_gain, sr, max(f32(0.001), noise_amp), 0, noise_dur)
	add_mono_to_stereo(out, breath_gain)

	if tail_amp > 0 {
		tail: ma.waveform
		tail_f0 := tail0 * (f32(0.97) + rand.float32() * f32(0.06))
		tail_f1 := max(f32(0.001), tail1 * (f32(0.97) + rand.float32() * f32(0.06)))
		tail_cfg := ma.waveform_config_init(.f32, 1, sr, .sine, 1, f64(tail_f0))
		if ma.waveform_init(&tail_cfg, &tail) != .SUCCESS {
			return
		}
		defer ma.waveform_uninit(&tail)
		tail_buf := make([]f32, frames)
		defer delete(tail_buf)
		read_waveform_ramp(&tail, tail_buf, sr, tail_f0, tail_f1, 0.06, 0.06 + tail_dur, .lin)
		tail_gain := make([]f32, frames)
		defer delete(tail_gain)
		gain_env(tail_buf, tail_gain, sr, max(f32(0.001), tail_amp), 0.06, 0.06 + tail_dur)
		add_mono_to_stereo(out, tail_gain)
	}

	submit_pcm(engine, out, sr)
}

@(private="file")
Ramp :: enum {
	lin,
	exp,
}

@(private="file")
read_waveform_ramp :: proc(w: ^ma.waveform, out: []f32, sr: u32, f0, f1, start, stop: f32, curve: Ramp) {
	n := len(out)
	i0 := clamp(int(start * f32(sr)), 0, n)
	i1 := clamp(int(stop * f32(sr)), 0, n)
	if i1 <= i0 {
		return
	}
	span := stop - start
	if f0 == f1 || span <= 0 {
		ma.waveform_set_frequency(w, f64(f0))
		ma.waveform_read_pcm_frames(w, raw_data(out[i0:i1]), u64(i1 - i0), nil)
		return
	}
	for i in i0 ..< i1 {
		x := (f32(i) / f32(sr) - start) / span
		f: f32
		if curve == .exp {
			a := max(f0, 0.001)
			b := max(f1, 0.001)
			f = a * math.pow(b / a, x)
		} else {
			f = f0 + (f1 - f0) * x
		}
		ma.waveform_set_frequency(w, f64(f))
		ma.waveform_read_pcm_frames(w, &out[i], 1, nil)
	}
}

@(private="file")
read_noise_window :: proc(src: ^ma.noise, out: []f32, sr: u32, start, stop: f32) {
	n := len(out)
	i0 := clamp(int(start * f32(sr)), 0, n)
	i1 := clamp(int(stop * f32(sr)), 0, n)
	if i1 <= i0 {
		return
	}
	ma.noise_read_pcm_frames(src, raw_data(out[i0:i1]), u64(i1 - i0), nil)
}

@(private="file")
Biquad_Kind :: enum {
	lowpass,
	highpass,
	bandpass,
	notch,
}

@(private="file")
rbj_config :: proc(sr: u32, kind: Biquad_Kind, freq, q: f32) -> ma.biquad_config {
	f := clamp(freq, 10, f32(sr) * 0.45)
	w := math.TAU * f / f32(sr)
	sin_w := math.sin(w)
	cos_w := math.cos(w)
	qq := max(q, 0.0001)
	alpha := sin_w / (2 * qq)
	b0, b1, b2, a0, a1, a2: f32
	switch kind {
	case .lowpass:
		b0 = (1 - cos_w) * 0.5
		b1 = 1 - cos_w
		b2 = (1 - cos_w) * 0.5
		a0 = 1 + alpha
		a1 = -2 * cos_w
		a2 = 1 - alpha
	case .highpass:
		b0 = (1 + cos_w) * 0.5
		b1 = -(1 + cos_w)
		b2 = (1 + cos_w) * 0.5
		a0 = 1 + alpha
		a1 = -2 * cos_w
		a2 = 1 - alpha
	case .bandpass:
		b0 = alpha
		b1 = 0
		b2 = -alpha
		a0 = 1 + alpha
		a1 = -2 * cos_w
		a2 = 1 - alpha
	case .notch:
		b0 = 1
		b1 = -2 * cos_w
		b2 = 1
		a0 = 1 + alpha
		a1 = -2 * cos_w
		a2 = 1 - alpha
	}
	return ma.biquad_config_init(.f32, 1, f64(b0 / a0), f64(b1 / a0), f64(b2 / a0), 1, f64(a1 / a0), f64(a2 / a0))
}

@(private="file")
biquad_init_rbj :: proc(bq: ^ma.biquad, sr: u32, kind: Biquad_Kind, freq, q: f32) -> bool {
	cfg := rbj_config(sr, kind, freq, q)
	return ma.biquad_init(&cfg, nil, bq) == .SUCCESS
}

@(private="file")
biquad_sweep :: proc(bq: ^ma.biquad, in_buf, out_buf: []f32, sr: u32, kind: Biquad_Kind, q, f0, f1, ramp_time: f32) {
	n := min(len(in_buf), len(out_buf))
	last := f0
	cfg := rbj_config(sr, kind, f0, q)
	ma.biquad_reinit(&cfg, bq)
	for i in 0 ..< n {
		f := f0
		if ramp_time > 0 && f1 != f0 {
			x := clamp((f32(i) / f32(sr)) / ramp_time, 0, 1)
			a := max(f0, 0.001)
			b := max(f1, 0.001)
			f = a * math.pow(b / a, x)
		}
		if abs(f - last) > 0.5 {
			cfg = rbj_config(sr, kind, f, q)
			ma.biquad_reinit(&cfg, bq)
			last = f
		}
		x := in_buf[i]
		ma.biquad_process_pcm_frames(bq, &out_buf[i], &x, 1)
	}
}

@(private="file")
gain_env :: proc(in_buf, out_buf: []f32, sr: u32, peak, start, stop: f32) {
	n := min(len(in_buf), len(out_buf))
	span := stop - start
	for i in 0 ..< n {
		t := f32(i) / f32(sr)
		g: f32 = 0
		if t >= start && t < stop && span > 0 {
			x := (t - start) / span
			a := max(peak, 0.001)
			g = a * math.pow(f32(0.001) / a, x)
		}
		out_buf[i] = in_buf[i] * g
	}
}

@(private="file")
add_mono_to_stereo :: proc(out, mono: []f32) {
	n := min(len(mono), len(out) / 2)
	for i in 0 ..< n {
		out[i * 2] += mono[i]
		out[i * 2 + 1] += mono[i]
	}
}
