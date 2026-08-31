@echo off
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
cd /d "%~dp0sokol-odin\sokol"
for %%s in (log app gfx glue debugtext) do (
    echo Building %%s debug
    cl /nologo /c /D_DEBUG /DIMPL /DSOKOL_D3D11 c\sokol_%%s.c /Z7
    if errorlevel 1 exit /b 1
    lib /nologo /OUT:%%s\sokol_%%s_windows_x64_d3d11_debug.lib sokol_%%s.obj
    del sokol_%%s.obj
    echo Building %%s release
    cl /nologo /c /O2 /DNDEBUG /DIMPL /DSOKOL_D3D11 c\sokol_%%s.c
    if errorlevel 1 exit /b 1
    lib /nologo /OUT:%%s\sokol_%%s_windows_x64_d3d11_release.lib sokol_%%s.obj
    del sokol_%%s.obj
)
echo Done.
