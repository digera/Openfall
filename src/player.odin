package main

import "core:math"

Player :: struct {
	pos:        vec3, // feet, metres
	vel_z:      f32,
	yaw:        f32,
	pitch:      f32,
	on_ground:  bool,
	hold_t:     f32,
	kick:       f32,
	kick_yaw:   f32,
	kick_pitch: f32,
	flash:      f32,
	fire_cd:    f32,
	shots:      int,
}

player_spawn :: proc() -> Player {
	return Player {
		pos = {
			0.5 * (ROOM_MIN.x + ROOM_MAX.x),
			0.5 * (ROOM_MIN.y + ROOM_MAX.y),
			ROOM_MIN.z,
		},
		yaw = 0, // +X
	}
}

player_eye :: proc(p: Player) -> vec3 {
	return {p.pos.x, p.pos.y, p.pos.z + PLAYER_EYE_M}
}

player_blocked :: proc(pos: vec3) -> bool {
	offs := [6]vec3 {
		{0, 0, 0.12},
		{0, 0, 0.32},
		{0, 0, PLAYER_H_M * 0.45},
		{0, 0, PLAYER_H_M * 0.88},
		{PLAYER_R_M * 0.7, 0, PLAYER_H_M * 0.5},
		{-PLAYER_R_M * 0.7, 0, PLAYER_H_M * 0.5},
	}
	for o in offs {
		q := pos + o
		if !room_inside(q, 0.02) {
			return true
		}
	}
	return false
}

player_ground :: proc(p: ^Player) {
	if p.pos.z <= ROOM_MIN.z + 0.001 {
		p.on_ground = true
		p.vel_z = 0
		p.pos.z = ROOM_MIN.z
		return
	}
	p.on_ground = false
}

player_move :: proc(p: ^Player, dt: f32) {
	fwd, str := input_wish_xy()
	wish_len := math.sqrt(fwd * fwd + str * str)
	if wish_len > 0 {
		fwd /= wish_len
		str /= wish_len
		look := camera_forward(p.yaw, 0)
		right := camera_right(p.yaw)
		step := PLAYER_WALK * dt
		vx := look.x * fwd + right.x * str
		vy := look.y * fwd + right.y * str
		try := p.pos
		try.x += vx * step
		if !player_blocked(try) {
			p.pos.x = try.x
		}
		try = p.pos
		try.y += vy * step
		if !player_blocked(try) {
			p.pos.y = try.y
		}
	}

	if p.on_ground {
		player_ground(p)
		if p.on_ground && input_consume_jump() {
			p.on_ground = false
			p.vel_z = PLAYER_JUMP
		} else {
			_ = input_consume_jump()
		}
	} else {
		_ = input_consume_jump()
		p.vel_z -= PLAYER_GRAVITY * dt
		try := p.pos
		try.z += p.vel_z * dt
		if try.z < ROOM_MIN.z {
			try.z = ROOM_MIN.z
			p.vel_z = 0
			p.on_ground = true
			p.pos.z = try.z
		} else if p.vel_z > 0 && player_blocked(try) {
			p.vel_z = 0
		} else if p.vel_z <= 0 && player_blocked(try) {
			p.vel_z = 0
			p.on_ground = true
		} else {
			p.pos.z = try.z
			player_ground(p)
		}
	}

	p.pos.x = clampf(p.pos.x, ROOM_MIN.x + PLAYER_R_M, ROOM_MAX.x - PLAYER_R_M)
	p.pos.y = clampf(p.pos.y, ROOM_MIN.y + PLAYER_R_M, ROOM_MAX.y - PLAYER_R_M)
}

player_apply_look :: proc(p: ^Player) {
	dx, dy := input_consume_look()
	p.yaw, p.pitch = camera_apply_look(p.yaw, p.pitch, dx, dy)
}

player_try_fire :: proc(p: ^Player, impacts: []Impact) {
	if p.fire_cd > 0 || !input.held_left {
		return
	}
	p.fire_cd = GUN_PERIOD
	p.shots += 1
	p.kick = 1
	p.flash = 1
	h := hash_u32(u32(p.shots) * 2654435761 + 17)
	p.kick_yaw = (f32(h & 0xFFFF) * (1.0 / 65535.0) - 0.5) * CAM_KICK_YAW
	p.kick_pitch = CAM_KICK_PITCH
	eye := player_eye(p^)
	rd := camera_forward(p.yaw, p.pitch)
	hit := room_trace(eye, rd, GUN_REACH_M)
	if hit.ok {
		impacts_push(impacts, hit.pos + hit.normal * 0.01)
	}
}

player_tick :: proc(p: ^Player, impacts: []Impact, dt: f32) {
	p.hold_t += dt
	p.kick = max(p.kick - 10 * dt, 0)
	p.flash = max(p.flash - 14 * dt, 0)
	if p.fire_cd > 0 {
		p.fire_cd = max(p.fire_cd - dt, 0)
	}
	player_try_fire(p, impacts)
	player_move(p, dt)
	impacts_tick(impacts, dt)
}
