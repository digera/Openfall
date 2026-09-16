package main

import "core:fmt"

// Verbose per-event server logging (casts, hits, bot decisions).
// Off by default: printing from the tick loop costs real frame time.
// Enable with: odin build ... -define:NEXUS_VERBOSE=true
SERVER_VERBOSE :: #config(NEXUS_VERBOSE, false)

server_log :: proc(format: string, args: ..any) {
	fmt.printf(format, ..args)
	fmt.println()
}
