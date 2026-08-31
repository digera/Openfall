# Odin FPS Template

A guy in an empty room with a gun.
: the Sokol loop, Z-up first-person body, mouse look, and viewmodel pose. Everything else (mine, grains, camp) is gone.

## Requirements

- [Odin](https://odin-lang.org/) (dev-2026-07 or newer)
- Visual Studio 2022/2026 x64 toolchain (sokol C libs)
- `sokol-shdc`

This machine:

| Tool | Path |
|---|---|
| Odin | `C:\Users\lusr\tools\odin\odin.exe` |
| sokol-shdc | `C:\Users\lusr\tools\sokol-shdc\sokol-shdc.exe` |

`third_party/sokol-odin` is vendored. First-time D3D11 libs: `third_party\build_sokol_d3d11.cmd` from an x64 VS prompt (or just run it — it calls vcvars itself).

## Build

```powershell
# First time: build sokol C libs from an x64 VS developer prompt
cd third_party\sokol-odin\sokol
.\build_clibs_windows.cmd
cd ..\..\..

.\build.ps1          # debug
.\build.ps1 -Release
.\build.ps1 -Run
```

Output: `bin\odinfps.exe`

## Controls

| Input | Effect |
|---|---|
| Click | Lock mouse |
| Mouse | Look |
| WASD | Walk |
| Space | Jump |
| Hold LMB | Fire |
| Esc | Unlock mouse |
