#!/usr/bin/env bash
# Build the Vulkan graphical client (SDL3 window, Vulkan renderer).
#
#   ODIN_ROOT     Odin installation (the compiler is $ODIN_ROOT/odin)
#   ODIN_TARGET   cross-compile, e.g. linux_arm64
#   BUILD_FLAGS   Odin flags (default: -debug, which also turns on the Vulkan
#                 validation layer when it is installed)
#   GLSLANG       glslangValidator (default: on PATH)
#
# Needs SDL 3.4 (libSDL3) at build and run time, and a Vulkan driver at run
# time. Output: bin/nexus_client_vk
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN_BIN="${ODIN_ROOT:?set ODIN_ROOT to the Odin installation}/odin"
SRC="$ROOT/src"
OUT="$ROOT/bin/nexus_client_vk"
STAGE="$ROOT/bin/vk_client_src"

command -v "${GLSLANG:-glslangValidator}" >/dev/null || {
	echo "glslangValidator not found (apt install glslang-tools, or set GLSLANG)" >&2
	exit 1
}

# Shared game code plus the graphical client and its Vulkan backend, with the
# SPIR-V the backend #loads beside it.
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp "$SRC"/*.odin "$SRC"/client/*.odin "$SRC"/client/vk/*.odin "$STAGE/"
"$ROOT/shaders/vk/compile.sh" "$STAGE/spv"

target_args=()
if [ -n "${ODIN_TARGET:-}" ]; then
	target_args+=(-target:"$ODIN_TARGET")
fi
# shellcheck disable=SC2086
"$ODIN_BIN" build "$STAGE" -out:"$OUT" -collection:game="$ROOT" "${target_args[@]}" ${BUILD_FLAGS:--debug}
rm -rf "$STAGE"
echo "Built $OUT"
