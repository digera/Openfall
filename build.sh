#!/bin/bash
# Build script for Nexus Arena (Linux/Unix)
# Usage: ./build.sh [server|client|both] [run]

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

BUILD_MODE="${1:-both}"

# Each target is the shared game code in src/*.odin plus its own folders.
stage() {
    local dest=$1
    shift
    rm -rf "$dest"
    mkdir -p "$dest"
    cp "$SRC_DIR"/*.odin "$dest/"
    local dir
    for dir in "$@"; do
        cp "$SRC_DIR/$dir"/*.odin "$dest/"
    done
}

# Build headless server
if [ "$BUILD_MODE" = "server" ] || [ "$BUILD_MODE" = "both" ]; then
    echo -e "${YELLOW}>> Building headless server...${NC}"

    TMP_SRC="$OUT_DIR/server_src"
    stage "$TMP_SRC" server

    $ODIN_BIN build "$TMP_SRC" -out:"$OUT_DIR/nexus_server" ${BUILD_FLAGS:--debug}
    rm -rf "$TMP_SRC"

    echo -e "${GREEN}✓ Server built${NC}"
fi

# Build headless test client
if [ "$BUILD_MODE" = "client" ] || [ "$BUILD_MODE" = "both" ]; then
    echo -e "${YELLOW}>> Building headless test client...${NC}"

    TMP_SRC="$OUT_DIR/client_src"
    stage "$TMP_SRC" test_client

    $ODIN_BIN build "$TMP_SRC" -out:"$OUT_DIR/nexus_client_test" ${BUILD_FLAGS:--debug}
    rm -rf "$TMP_SRC"

    echo -e "${GREEN}✓ Test client built${NC}"
fi

echo -e "${GREEN}>> Build complete!${NC}"
[ "$BUILD_MODE" = "server" ] || [ "$BUILD_MODE" = "both" ] && echo -e "  Server: $OUT_DIR/nexus_server"
[ "$BUILD_MODE" = "client" ] || [ "$BUILD_MODE" = "both" ] && echo -e "  Test Client: $OUT_DIR/nexus_client_test"

# Run if requested
if [ "${2:-}" == "run" ]; then
    if [ "$BUILD_MODE" = "server" ]; then
        echo -e "\n${GREEN}>> Running server...${NC}\n"
        exec "$OUT_DIR/nexus_server"
    elif [ "$BUILD_MODE" = "client" ]; then
        echo -e "\n${GREEN}>> Running test client...${NC}\n"
        exec "$OUT_DIR/nexus_client_test"
    fi
fi
