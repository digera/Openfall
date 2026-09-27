#!/usr/bin/env bash
# Compile the Vulkan backend's shaders to SPIR-V in OUT_DIR, where
# src/client/vk #loads them from. The reference ray tracer is the fragment
# stage of shaders/scene.glsl, cut out of its sokol-shdc markup unchanged.
#
#   GLSLANG   glslangValidator (default: on PATH)
#
# Usage: shaders/vk/compile.sh OUT_DIR
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:?usage: compile.sh OUT_DIR}"
GLSLANG="${GLSLANG:-glslangValidator}"
mkdir -p "$OUT"

{
	echo "#version 450"
	sed -n '/^@fs fs$/,/^@end$/p' "$HERE/../scene.glsl" | sed '1d;$d'
} > "$OUT/scene_ref.frag"

compile() {
	"$GLSLANG" -V --quiet -I"$HERE" --auto-map-locations -o "$OUT/$2" "$1"
}
compile "$OUT/scene_ref.frag"      scene_ref.frag.spv
compile "$HERE/scene_ref.vert"     scene_ref.vert.spv
compile "$HERE/hud.vert"           hud.vert.spv
compile "$HERE/hud.frag"           hud.frag.spv
rm -f "$OUT/scene_ref.frag"
