# Type-check the server and client packages without linking.
# build.ps1 links into bin\ which can be locked by a running binary; this only
# needs the compiler front end.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Odin = if ($env:ODIN_ROOT) { Join-Path $env:ODIN_ROOT "odin.exe" } else { "C:\Users\lusr\tools\odin\odin.exe" }
$Sokol = Join-Path $Root "third_party\sokol-odin\sokol"
if (-not (Test-Path $Sokol)) {
    $Sokol = "C:\Users\lusr\yearning\third_party\sokol-odin\sokol"
}
$SrcDir = Join-Path $Root "src"
$Stage = Join-Path $env:TEMP "nexus_check"

# Each target is the shared game code in src\*.odin plus its own folders.
function Stage-Sources {
    param([string]$Dest, [string[]]$Dirs)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    foreach ($dir in @($SrcDir) + @($Dirs | ForEach-Object { Join-Path $SrcDir $_ })) {
        Get-ChildItem -Path $dir -Filter "*.odin" -File | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $Dest $_.Name)
        }
    }
}

$fail = 0

Write-Host ">> Checking headless server..."
$srv = Join-Path $Stage "server"
Stage-Sources -Dest $srv -Dirs @("server")
& $Odin check $srv
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ">> Checking graphical client..."
$cli = Join-Path $Stage "client"
Stage-Sources -Dest $cli -Dirs @("client", "client/sokol")
& $Odin check $cli "-collection:sokol=$Sokol" "-collection:game=$Root"
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ">> Checking Vulkan client..."
$vkc = Join-Path $Stage "client_vk"
Stage-Sources -Dest $vkc -Dirs @("client", "client/vk")
& (Join-Path $Root "shaders/vk/compile.ps1") -OutDir (Join-Path $vkc "spv")
& $Odin check $vkc "-collection:game=$Root"
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ">> Checking headless test client..."
$tc = Join-Path $Stage "testclient"
Stage-Sources -Dest $tc -Dirs @("test_client")
& $Odin check $tc
if ($LASTEXITCODE -ne 0) { $fail = 1 }

if ($fail -eq 0) { Write-Host ">> OK" } else { Write-Host ">> FAILED"; exit 1 }
