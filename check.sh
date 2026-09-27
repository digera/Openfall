#!/usr/bin/env bash
# Type-check the server, graphical client and headless test client without
# linking. Mirrors check.ps1.
#
#   ODIN_BIN     compiler (default: $ODIN_ROOT/odin, else odin on PATH)
#   ODIN_TARGET  cross-check for another platform, e.g. linux_arm64
#   SHDC         sokol-shdc, only needed if src/client/sokol/scene.odin is
#                missing or older than shaders/scene.glsl
#
# Each target is the shared game code in src/*.odin plus its own folders:
#   server       src/server
#   client       src/client, src/client/sokol
#   testclient   src/test_client
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/src"
SOKOL="${SOKOL:-$ROOT/third_party/sokol-odin/sokol}"
STAGE="${TMPDIR:-/tmp}/openfall_check"

if [ -z "${ODIN_BIN:-}" ]; then
	if [ -n "${ODIN_ROOT:-}" ]; then
		ODIN_BIN="$ODIN_ROOT/odin"
	else
		ODIN_BIN="$(command -v odin || true)"
	fi
fi
if [ -z "$ODIN_BIN" ] || [ ! -x "$ODIN_BIN" ]; then
	echo "Odin compiler not found; set ODIN_BIN or ODIN_ROOT" >&2
	exit 1
fi

target_args=()
if [ -n "${ODIN_TARGET:-}" ]; then
	target_args+=(-target:"$ODIN_TARGET")
fi

stage() {
	local dest=$1
	shift
	rm -rf "$dest"
	mkdir -p "$dest"
	cp "$SRC"/*.odin "$dest/"
	local dir
	for dir in "$@"; do
		cp "$SRC/$dir"/*.odin "$dest/"
	done
}

scene="$SRC/client/sokol/scene.odin"
if [ ! -f "$scene" ] || [ "$ROOT/shaders/scene.glsl" -nt "$scene" ]; then
	: "${SHDC:?src/client/sokol/scene.odin is missing or stale; set SHDC to sokol-shdc}"
	"$SHDC" -i "$ROOT/shaders/scene.glsl" -o "$scene" \
		-l hlsl5:glsl430:metal_macos:wgsl -f sokol_odin
fi

fail=0

echo ">> Checking headless server..."
stage "$STAGE/server" server
"$ODIN_BIN" check "$STAGE/server" "${target_args[@]}" || fail=1

echo ">> Checking graphical client..."
stage "$STAGE/client" client client/sokol
"$ODIN_BIN" check "$STAGE/client" "${target_args[@]}" \
	-collection:sokol="$SOKOL" -collection:game="$ROOT" || fail=1

echo ">> Checking headless test client..."
stage "$STAGE/testclient" test_client
"$ODIN_BIN" check "$STAGE/testclient" "${target_args[@]}" || fail=1

if [ "$fail" -eq 0 ]; then
	echo ">> OK"
else
	echo ">> FAILED"
	exit 1
fi
