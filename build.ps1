param(
    [switch]$Run,
    [switch]$Release
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Odin = if ($env:ODIN_ROOT) { Join-Path $env:ODIN_ROOT "odin.exe" } else { "C:\Users\lusr\tools\odin\odin.exe" }
$Shdc = "C:\Users\lusr\tools\sokol-shdc\sokol-shdc.exe"
$Sokol = Join-Path $Root "third_party\sokol-odin\sokol"
if (-not (Test-Path $Sokol)) {
    $Sokol = "C:\Users\lusr\yearning\third_party\sokol-odin\sokol"
}
$OutDir = Join-Path $Root "bin"
$Out = Join-Path $OutDir "odinfps.exe"

if (-not (Test-Path $Odin)) {
    Write-Error "Odin not found at $Odin. Set ODIN_ROOT or install to C:\Users\lusr\tools\odin"
}
if (-not (Test-Path $Shdc)) {
    Write-Error "sokol-shdc not found at $Shdc"
}
if (-not (Test-Path $Sokol)) {
    Write-Error "sokol-odin missing. Copy yearning/third_party/sokol-odin into third_party/"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Write-Host ">> Compiling shaders..."
& $Shdc `
    -i (Join-Path $Root "shaders\scene.glsl") `
    -o (Join-Path $Root "src\scene.odin") `
    -l hlsl5:glsl430:metal_macos:wgsl `
    -f sokol_odin
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$modeArgs = @()
if ($Release) {
    $modeArgs += "-o:speed"
} else {
    $modeArgs += "-debug"
}

Write-Host ">> Building odinfps..."
& $Odin build (Join-Path $Root "src") `
    -out:$Out `
    "-collection:sokol=$Sokol" `
    @modeArgs
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ">> Built $Out"
if ($Run) {
    & $Out
}
