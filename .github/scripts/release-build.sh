#!/usr/bin/env bash
# Release build of the headless server and graphical client.
# Staging matches build.ps1. Writes archives under bin/release/.
#
#   ODIN_BIN   compiler
#   VERSION    0.0.1.0
#   SHDC       sokol-shdc (client)
#   SOKOL      third_party/sokol-odin/sokol (client)
#
# Usage: release-build.sh [server|client|both]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$ROOT/src"
TARGET="${1:-both}"
: "${ODIN_BIN:?ODIN_BIN is required}"
: "${VERSION:?VERSION is required}"

case "$(uname -s)" in
	Linux) OS=linux ;;
	MINGW*|MSYS*|CYGWIN*) OS=windows ;;
	*)
		echo "unsupported OS: $(uname -s)" >&2
		exit 1
		;;
esac

if [ "$OS" = windows ]; then
	CLIENT_BIN="nexus_client.exe"
	SERVER_BIN="nexus_server.exe"
else
	CLIENT_BIN="nexus_client"
	SERVER_BIN="nexus_server"
fi

# Keep in sync with build.ps1.
SERVER_EXCLUDE=(
	input.odin scene.odin
	main_client.odin client_renderer.odin client_audio.odin
	main_test_client.odin main_combat_test.odin
	postgres.odin persistence.odin
)
CLIENT_EXCLUDE=(
	main_server.odin server.odin bots.odin
	main_test_client.odin main_combat_test.odin camera_minimal.odin
	postgres.odin persistence.odin
)

stage_sources() {
	local dest=$1
	shift
	local exclude=("$@")
	rm -rf "$dest"
	mkdir -p "$dest"
	local f base skip ex
	for f in "$SRC"/*.odin; do
		base=$(basename "$f")
		skip=0
		for ex in "${exclude[@]}"; do
			if [ "$base" = "$ex" ]; then
				skip=1
				break
			fi
		done
		if [ "$skip" -eq 0 ]; then
			cp "$f" "$dest/"
		fi
	done
}

compile_shaders() {
	: "${SHDC:?SHDC is required to build the client}"
	echo ">> Compiling shaders"
	"$SHDC" \
		-i "$ROOT/shaders/scene.glsl" \
		-o "$SRC/scene.odin" \
		-l hlsl5:glsl430:metal_macos:wgsl \
		-f sokol_odin
}

build_server() {
	local staged="$ROOT/bin/server_src"
	local out="$ROOT/bin/$SERVER_BIN"
	echo ">> Building headless server"
	stage_sources "$staged" "${SERVER_EXCLUDE[@]}"
	if [ ! -f "$staged/main_server.odin" ]; then
		echo "staged server sources missing main_server.odin" >&2
		exit 1
	fi
	mv -f "$staged/main_server.odin" "$staged/main.odin"
	"$ODIN_BIN" build "$staged" -out:"$out" -o:speed
	rm -rf "$staged"
	pack server "$out" "$SERVER_BIN"
}

build_client() {
	: "${SOKOL:?SOKOL is required to build the client}"
	local staged="$ROOT/bin/gfx_client_src"
	local out="$ROOT/bin/$CLIENT_BIN"
	compile_shaders
	echo ">> Building graphical client"
	stage_sources "$staged" "${CLIENT_EXCLUDE[@]}"
	if [ ! -f "$staged/scene.odin" ]; then
		echo "staged client sources missing scene.odin" >&2
		exit 1
	fi
	local -a extra=()
	if [ "$OS" = linux ]; then
		extra+=(-extra-linker-flags:"-lGL -lX11 -lXi -lXcursor -lasound -lpthread -lm -ldl")
	fi
	if [ "${#extra[@]}" -eq 0 ]; then
		"$ODIN_BIN" build "$staged" -out:"$out" -o:speed \
			-collection:sokol="$SOKOL" \
			-collection:game="$ROOT"
	else
		"$ODIN_BIN" build "$staged" -out:"$out" -o:speed \
			-collection:sokol="$SOKOL" \
			-collection:game="$ROOT" \
			"${extra[@]}"
	fi
	rm -rf "$staged"
	pack client "$out" "$CLIENT_BIN"
}

pack() {
	local kind=$1
	local bin=$2
	local name=$3
	local stage archive
	if [ ! -f "$bin" ]; then
		echo "missing binary: $bin" >&2
		exit 1
	fi
	stage=$(mktemp -d)
	cp "$bin" "$stage/$name"
	cp "$ROOT/LICENSE" "$stage/LICENSE"
	mkdir -p "$ROOT/bin/release"
	if [ "$OS" = linux ]; then
		chmod +x "$stage/$name"
		local magic
		magic=$(od -An -tx1 -N4 "$stage/$name" | tr -d ' \n')
		if [ "$magic" != "7f454c46" ]; then
			echo "$name is not a Linux ELF (magic $magic)" >&2
			exit 1
		fi
		archive="$ROOT/bin/release/openfall-${VERSION}-linux-amd64-${kind}.tar.gz"
		tar -C "$stage" -czf "$archive" "$name" LICENSE
	else
		archive="$ROOT/bin/release/openfall-${VERSION}-windows-amd64-${kind}.zip"
		rm -f "$archive"
		# Git Bash's tar.exe is GNU tar and treats "C:" as a remote host.
		# Windows bsdtar writes the zip.
		local win_root win_tar
		win_root=$(cygpath -u "${SYSTEMROOT:-C:/Windows}")
		win_tar="$win_root/System32/tar.exe"
		"$win_tar" -a -c -f "$(cygpath -w "$archive")" -C "$(cygpath -w "$stage")" "$name" LICENSE
	fi
	rm -rf "$stage"
	echo ">> Packed $archive"
}

mkdir -p "$ROOT/bin"

case "$TARGET" in
	server) build_server ;;
	client) build_client ;;
	both)
		build_server
		build_client
		;;
	*)
		echo "usage: release-build.sh [server|client|both]" >&2
		exit 1
		;;
esac
