# Toolchain setup for the release workflow.
# Sourced from bash. Expects ODIN_RELEASE, SOKOL_ODIN_SHA, and SOKOL_SHDC_SHA.

ci_root() {
	local here
	here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	(cd "$here/../.." && pwd)
}

ci_os() {
	case "$(uname -s)" in
		Linux) echo linux ;;
		MINGW*|MSYS*|CYGWIN*) echo windows ;;
		*)
			echo "unsupported OS: $(uname -s)" >&2
			return 1
			;;
	esac
}

ci_tools_dir() {
	local base="${RUNNER_TEMP:-$ROOT/.tools}"
	if [ "$(ci_os)" = windows ]; then
		base="$(cygpath -u "$base")"
	fi
	printf '%s\n' "$base"
}

install_odin() {
	local tools os asset
	os=$(ci_os)
	tools="$(ci_tools_dir)/odin"
	mkdir -p "$tools/unpack"
	if [ "$os" = linux ]; then
		asset="odin-linux-amd64-${ODIN_RELEASE}.tar.gz"
	else
		asset="odin-windows-amd64-${ODIN_RELEASE}.zip"
	fi
	echo ">> Downloading Odin ${ODIN_RELEASE}"
	curl -fL --retry 3 --retry-delay 2 \
		"https://github.com/odin-lang/Odin/releases/download/${ODIN_RELEASE}/${asset}" \
		-o "$tools/odin-pkg"
	if [ "$os" = windows ]; then
		powershell.exe -NoProfile -Command "Expand-Archive -Force -LiteralPath '$(cygpath -w "$tools/odin-pkg")' -DestinationPath '$(cygpath -w "$tools/unpack")'"
	else
		tar -xzf "$tools/odin-pkg" -C "$tools/unpack"
	fi
	ODIN_BIN=$(find "$tools/unpack" -type f \( -name odin -o -name odin.exe \) -print -quit)
	if [ -z "$ODIN_BIN" ]; then
		echo "Odin package did not contain an odin binary" >&2
		return 1
	fi
	chmod +x "$ODIN_BIN" 2>/dev/null || true
	export ODIN_BIN
	export ODIN_ROOT
	ODIN_ROOT=$(dirname "$ODIN_BIN")
	"$ODIN_BIN" version
}

install_shdc() {
	local tools
	tools="$(ci_tools_dir)/shdc"
	local os name url
	os=$(ci_os)
	mkdir -p "$tools"
	if [ "$os" = linux ]; then
		name="sokol-shdc"
		url="https://raw.githubusercontent.com/floooh/sokol-tools-bin/${SOKOL_SHDC_SHA}/bin/linux/sokol-shdc"
	else
		name="sokol-shdc.exe"
		url="https://raw.githubusercontent.com/floooh/sokol-tools-bin/${SOKOL_SHDC_SHA}/bin/win32/sokol-shdc.exe"
	fi
	echo ">> Downloading sokol-shdc"
	curl -fL --retry 3 --retry-delay 2 "$url" -o "$tools/$name"
	chmod +x "$tools/$name" 2>/dev/null || true
	if head -c 80 "$tools/$name" | grep -q "git-lfs"; then
		echo "sokol-shdc download is a git-lfs pointer" >&2
		return 1
	fi
	export SHDC="$tools/$name"
}

clone_sokol() {
	local dest="$ROOT/third_party/sokol-odin"
	rm -rf "$dest"
	mkdir -p "$ROOT/third_party"
	echo ">> Cloning sokol-odin ${SOKOL_ODIN_SHA}"
	git init "$dest"
	git -C "$dest" remote add origin https://github.com/floooh/sokol-odin.git
	git -C "$dest" fetch --depth 1 origin "$SOKOL_ODIN_SHA"
	git -C "$dest" checkout --detach FETCH_HEAD
	export SOKOL="$dest/sokol"
}
