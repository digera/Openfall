package main

Hit :: struct {
	ok:     bool,
	pos:    vec3,
	normal: vec3,
	dist:  f32,
}

Impact :: struct {
	pos:  vec3,
	age:  f32,
	live: bool,
}

room_inside :: proc(pos: vec3, pad: f32) -> bool {
	return pos.x >= ROOM_MIN.x + pad &&
		pos.x <= ROOM_MAX.x - pad &&
		pos.y >= ROOM_MIN.y + pad &&
		pos.y <= ROOM_MAX.y - pad &&
		pos.z >= ROOM_MIN.z &&
		pos.z <= ROOM_MAX.z - pad
}

// Interior AABB exit — the player lives inside the box.
room_trace :: proc(ro, rd_in: vec3, max_t: f32) -> Hit {
	rd := norm_vec3(rd_in)
	if abs(rd.x) < 1e-7 {
		rd.x = rd.x < 0 ? -1e-7 : 1e-7
	}
	if abs(rd.y) < 1e-7 {
		rd.y = rd.y < 0 ? -1e-7 : 1e-7
	}
	if abs(rd.z) < 1e-7 {
		rd.z = rd.z < 0 ? -1e-7 : 1e-7
	}
	inv := vec3{1 / rd.x, 1 / rd.y, 1 / rd.z}
	tbot := (ROOM_MIN - ro) * inv
	ttop := (ROOM_MAX - ro) * inv
	ts := vec3{min(ttop.x, tbot.x), min(ttop.y, tbot.y), min(ttop.z, tbot.z)}
	tb := vec3{max(ttop.x, tbot.x), max(ttop.y, tbot.y), max(ttop.z, tbot.z)}
	t0 := max(ts.x, ts.y, ts.z)
	t1 := min(tb.x, tb.y, tb.z)
	if t1 < max(t0, 0) {
		return {}
	}
	t := t0 > 0.02 ? t0 : t1
	if t < 0 || t > max_t {
		return {}
	}
	hp := ro + rd * t
	n: vec3
	eps :: f32(0.002)
	if abs(hp.x - ROOM_MIN.x) < eps {
		n = {1, 0, 0}
	} else if abs(hp.x - ROOM_MAX.x) < eps {
		n = {-1, 0, 0}
	} else if abs(hp.y - ROOM_MIN.y) < eps {
		n = {0, 1, 0}
	} else if abs(hp.y - ROOM_MAX.y) < eps {
		n = {0, -1, 0}
	} else if abs(hp.z - ROOM_MIN.z) < eps {
		n = {0, 0, 1}
	} else {
		n = {0, 0, -1}
	}
	return Hit{ok = true, pos = hp, normal = n, dist = t}
}

impacts_push :: proc(impacts: []Impact, pos: vec3) {
	oldest := 0
	oldest_age: f32 = -1
	for i in 0 ..< len(impacts) {
		if !impacts[i].live {
			impacts[i] = {pos = pos, age = 1, live = true}
			return
		}
		if impacts[i].age < oldest_age || oldest_age < 0 {
			oldest = i
			oldest_age = impacts[i].age
		}
	}
	impacts[oldest] = {pos = pos, age = 1, live = true}
}

impacts_tick :: proc(impacts: []Impact, dt: f32) {
	for &im in impacts {
		if !im.live {
			continue
		}
		im.age = max(im.age - dt * 0.35, 0)
		if im.age <= 0 {
			im.live = false
		}
	}
}
