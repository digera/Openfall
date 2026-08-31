package main

import "core:math"

Camera :: struct {
	eye:    vec3,
	target: vec3,
	up:     vec3,
	yaw:    f32,
	pitch:  f32,
	half_w: f32,
	half_h: f32,
}

Camera_Basis :: struct {
	pos:     vec3,
	right:   vec3,
	up:      vec3,
	forward: vec3,
	half_w:  f32,
	half_h:  f32,
}

camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}

camera_apply_look :: proc(yaw, pitch: f32, dx, dy: f32) -> (f32, f32) {
	yaw_out := yaw - dx * CAM_LOOK_SENS
	pitch_out := clampf(pitch - dy * CAM_LOOK_SENS, -CAM_PITCH_MAX, CAM_PITCH_MAX)
	return yaw_out, pitch_out
}

camera_from_player :: proc(p: Player, aspect: f32) -> Camera {
	eye := player_eye(p)
	kick := p.kick * p.kick
	yaw := p.yaw + p.kick_yaw * kick
	pitch := clampf(p.pitch - p.kick_pitch * kick, -CAM_PITCH_MAX, CAM_PITCH_MAX)
	fwd := camera_forward(yaw, pitch)
	fov := f32(CAM_FOV_DEG)
	if kick > 0.002 {
		fov -= CAM_FOV_KICK * kick
	}
	half_h := math.tan(fov * math.PI / 360.0)
	half_w := half_h * max(aspect, f32(0.01))
	return Camera {
		eye    = eye,
		target = eye + fwd,
		up     = {0, 0, 1},
		yaw    = yaw,
		pitch  = pitch,
		half_w = half_w,
		half_h = half_h,
	}
}

camera_basis :: proc(cam: Camera, aspect: f32) -> Camera_Basis {
	forward := camera_forward(cam.yaw, cam.pitch)
	right := camera_right(cam.yaw)
	up := norm_vec3(cross_vec3(right, forward))
	half_h := cam.half_h
	half_w := cam.half_w
	if half_h <= 0 {
		half_h = math.tan(f32(CAM_FOV_DEG) * math.PI / 360.0)
		half_w = half_h * max(aspect, 0.01)
	}
	return Camera_Basis {
		pos     = cam.eye,
		right   = right,
		up      = up,
		forward = forward,
		half_w  = half_w,
		half_h  = half_h,
	}
}

// Oriented pistol in the camera's hands. Recoil pulls the grip back and up.
camera_gun_pose :: proc(cam: Camera, kick, hold_t: f32) -> (grip, muzzle, right, up: vec3) {
	basis := camera_basis(cam, 1)
	bob_u := 0.008 * math.sin(hold_t * 2.15)
	bob_r := 0.005 * math.sin(hold_t * 1.63 + 0.4)
	recoil := kick * kick
	grip = basis.pos +
		basis.right * (0.22 + bob_r) +
		basis.up * (-0.20 + bob_u + recoil * 0.04) +
		basis.forward * (0.38 - recoil * 0.07)
	muzzle = grip +
		basis.forward * 0.34 +
		basis.up * (-0.012 + recoil * 0.03) +
		basis.right * 0.008
	right = basis.right
	up = norm_vec3(cross_vec3(right, muzzle - grip))
	return
}
