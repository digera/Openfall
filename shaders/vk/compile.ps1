# Compile the Vulkan backend's shaders to SPIR-V in OutDir. Mirrors compile.sh.
#
#   GLSLANG   glslangValidator (default: $env:VULKAN_SDK\Bin, else on PATH)
#
# Usage: shaders\vk\compile.ps1 -OutDir <dir>
param([Parameter(Mandatory = $true)][string]$OutDir)
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

$Glslang = $env:GLSLANG
if (-not $Glslang) {
    $sdk = if ($env:VULKAN_SDK) { Join-Path (Join-Path $env:VULKAN_SDK "Bin") "glslangValidator.exe" } else { "" }
    $Glslang = if ($sdk -and (Test-Path $sdk)) { $sdk } else { "glslangValidator" }
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

# The reference ray tracer is the fragment stage of shaders/scene.glsl, cut
# out of its sokol-shdc markup unchanged.
$scene = Get-Content (Join-Path $Here "../scene.glsl")
$start = [Array]::IndexOf($scene, "@fs fs")
$end = $start + 1
while ($scene[$end] -ne "@end") { $end++ }
$frag = Join-Path $OutDir "scene_ref.frag"
Set-Content -Path $frag -Value (@("#version 450") + $scene[($start + 1)..($end - 1)])

function Compile([string]$Src, [string]$Name) {
    & $Glslang -V --quiet "-I$Here" --auto-map-locations -o (Join-Path $OutDir $Name) $Src
    if ($LASTEXITCODE -ne 0) { throw "glslangValidator failed on $Src" }
}
Compile $frag "scene_ref.frag.spv"
Compile (Join-Path $Here "scene_ref.vert") "scene_ref.vert.spv"
Compile (Join-Path $Here "hud.vert") "hud.vert.spv"
Compile (Join-Path $Here "hud.frag") "hud.frag.spv"
Remove-Item $frag
