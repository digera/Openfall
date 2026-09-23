@echo off
setlocal
rem Static D3D11 release libs the graphical client links. Run from an x64 VS prompt.
cd /d "%~dp0..\..\third_party\sokol-odin\sokol"
if not exist c\sokol_app.c (
    echo sokol-odin is not checked out at third_party\sokol-odin
    exit /b 1
)
for %%s in (log app gfx glue debugtext) do (
    echo Building %%s
    cl /nologo /c /O2 /DNDEBUG /DIMPL /DSOKOL_D3D11 c\sokol_%%s.c
    if errorlevel 1 exit /b 1
    lib /nologo /OUT:%%s\sokol_%%s_windows_x64_d3d11_release.lib sokol_%%s.obj
    if errorlevel 1 exit /b 1
    del sokol_%%s.obj
)
echo Sokol D3D11 release libs ready.
