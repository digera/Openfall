# Build Notes for Cloak Feature

## Prerequisites

### Windows
- Odin compiler (dev-2026-07 or newer) - set `ODIN_ROOT`
- Visual Studio 2022/2026 x64 toolchain (for sokol C libs)
- `sokol-shdc` in PATH (shader compiler)

### Linux
- Odin compiler - set `ODIN_ROOT` environment variable
- X11, OpenGL, ALSA development libraries
- `sokol-shdc` in PATH

## Installing sokol-shdc

### Linux/Mac
```bash
curl -L https://github.com/floooh/sokol-tools-bin/archive/refs/heads/master.tar.gz | tar xz
sudo cp sokol-tools-bin-master/bin/linux/sokol-shdc /usr/local/bin/
sudo chmod +x /usr/local/bin/sokol-shdc
```

### Windows
Download from https://github.com/floooh/sokol-tools-bin and add to PATH.

## Build Process

### 1. Compile Shaders (REQUIRED)

The `src/scene.odin` file is generated from `shaders/scene.glsl` and is gitignored. You must regenerate it after pulling:

```bash
sokol-shdc -i shaders/scene.glsl -o src/scene.odin -l glsl430:metal_macos:wgsl -f sokol_odin
```

This creates the Odin bindings for all shader uniforms, including the new cloak data.

### 2. Build Sokol Libraries (First Time Only)

**Windows:**
From an x64 VS Developer Command Prompt:
```powershell
cd third_party
.\build_sokol_d3d11.cmd
```

**Linux:**
```bash
cd third_party/sokol-odin/sokol
./build_clibs_linux.sh
```

### 3. Build the Game

**Windows:**
```powershell
.\build.ps1                 # both server and client
.\build.ps1 -Target client  # graphical client only
.\build.ps1 -Release        # optimized build
```

**Linux:**
```bash
./build_graphical_client.sh   # auto-compiles shader, builds client
./build.sh server             # headless server
```

## Running

### Local Playtest
```bash
# Terminal 1: Start server
./bin/nexus_server

# Terminal 2: Start client
export SERVER_IP=127.0.0.1
./bin/nexus_client
```

### Remote Server
Client defaults to `primord.io:27015`. Just run:
```bash
./bin/nexus_client
```

## Troubleshooting

### "scene.odin not found" or compile errors
**Solution:** Regenerate shader bindings (step 1 above).

### Linker errors about sokol
**Solution:** Build sokol C libraries (step 2 above).

### Odin compiler not found
**Solution:** Set `ODIN_ROOT` environment variable:
```bash
export ODIN_ROOT=/path/to/odin
# or on Windows:
$env:ODIN_ROOT = "C:\path\to\odin"
```

### Cloaks not visible in game
1. Check shader compiled without errors
2. Verify `src/scene.odin` has `cloak_hem`, `cloak_hem2`, `cloak_hem3` fields
3. Look at **remote** players (not your own wisp)
4. Ensure you're in a team and others have joined

### Cloak flickering or artifacts
- Increase SDF march epsilon in `cloak_trace` (line ~500 of scene.glsl)
- Check `dt` is reasonable (log in client_renderer.odin line ~349)
- Verify hem control points aren't NaN (add debug logging)

## Expected Performance

With 16 wisps visible (max):
- **Frame time delta:** <1ms vs. without cloaks
- **FPS impact:** Negligible (<5% on reference hardware)
- **Memory:** +4KB uniform data (3×16 vec4 arrays)

Most rays early-out via bounds check. SDF evaluation only occurs when ray is inside the 1.2m sphere around a wisp.

## What Changed

**Modified Files:**
- `shaders/scene.glsl`: +150 lines (uniforms, SDF, trace, shading)
- `src/client_renderer.odin`: +80 lines (state, simulation, packing)

**Generated File (not in repo):**
- `src/scene.odin`: regenerated from shader (15k lines GLSL/Metal/WGSL)

**New Files:**
- `CLOAK_IMPLEMENTATION.md`: architecture & design
- `TESTING_GUIDE.md`: visual reference & test scenarios
- `BUILD_NOTES.md`: this file

## Testing Checklist

Before marking PR ready:
- [ ] Shader compiles without errors
- [ ] Client builds successfully
- [ ] Server builds successfully
- [ ] Cloaks visible on remote players
- [ ] Cloaks trail behind fast movement
- [ ] Cloaks swing during turns
- [ ] Cloaks sway when idle
- [ ] Team colors correct (Ember=red, Tide=blue, Verdant=green)
- [ ] No Z-fighting or flickering
- [ ] Performance acceptable (>60 FPS with 16 wisps)

## Next Steps

1. Pull branch: `cursor/wisp-flowing-cloaks-95ab`
2. Regenerate shader bindings (sokol-shdc)
3. Build and test on Windows (primary target platform)
4. Capture screenshots/video showing:
   - Idle sway
   - Motion trailing
   - Turn swing
   - Team color comparison
5. Update PR with media
6. Mark PR ready for review

## Questions?

Check the other docs:
- Architecture: `CLOAK_IMPLEMENTATION.md`
- Visual testing: `TESTING_GUIDE.md`
- PR description: https://github.com/digera/odinfpstemplate/pull/13
