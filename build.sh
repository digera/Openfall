#!/bin/bash
# Build script for Nexus Arena (Linux/Unix)

set -e

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODIN_BIN="${ODIN_ROOT}/odin"
OUT_DIR="$ROOT/bin"
SRC_DIR="$ROOT/src"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

if [ ! -x "$ODIN_BIN" ]; then
    echo -e "${RED}Error: Odin compiler not found at $ODIN_BIN${NC}"
    echo -e "Set ODIN_ROOT environment variable to Odin installation directory"
    exit 1
fi

echo -e "${GREEN}=== Building Nexus Arena ===${NC}"

# Create output directory
mkdir -p "$OUT_DIR"

# Build headless server (exclude client-only files)
echo -e "${YELLOW}>> Building headless server...${NC}"

# Create temporary directory with only server files
TMP_SRC="$OUT_DIR/server_src"
rm -rf "$TMP_SRC"
mkdir -p "$TMP_SRC"

# Copy server files (exclude client files)
for f in "$SRC_DIR"/*.odin; do
    base=$(basename "$f")
    if [[ "$base" != "render.odin" && "$base" != "input.odin" && "$base" != "scene.odin" && "$base" != "main.odin" && "$base" != "player.odin" && "$base" != "camera.odin" ]]; then
        cp "$f" "$TMP_SRC/"
    fi
done

# Rename main_server.odin to main.odin for build
mv "$TMP_SRC/main_server.odin" "$TMP_SRC/main.odin" 2>/dev/null || true

$ODIN_BIN build "$TMP_SRC" \
    -out:"$OUT_DIR/nexus_server" \
    ${BUILD_FLAGS:--debug}

# Clean up temp
rm -rf "$TMP_SRC"

echo -e "${GREEN}>> Build complete!${NC}"
echo -e "  Server: $OUT_DIR/nexus_server"

# Run if requested
if [ "${1:-}" == "run" ] || [ "${2:-}" == "run" ]; then
    echo -e "\n${GREEN}>> Running server...${NC}\n"
    exec "$OUT_DIR/nexus_server"
fi
