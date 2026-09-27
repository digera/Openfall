package main

import "core:math"

// View-direction helpers shared by the simulation and every client

camera_forward :: proc(yaw, pitch: f32) -> vec3 {
	cp := math.cos(pitch)
	return {math.cos(yaw) * cp, math.sin(yaw) * cp, math.sin(pitch)}
}

camera_right :: proc(yaw: f32) -> vec3 {
	return {math.sin(yaw), -math.cos(yaw), 0}
}
