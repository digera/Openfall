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

$serverExclude = @(
    "input.odin", "scene.odin",
    "main_client.odin", "client_renderer.odin", "client_audio.odin", "main_test_client.odin", "main_combat_test.odin",
    "postgres.odin", "persistence.odin"
)
$clientExclude = @(
    "main_server.odin", "server.odin", "bots.odin",
    "main_test_client.odin", "main_combat_test.odin", "camera_minimal.odin",
    "postgres.odin", "persistence.odin"
)
$testClientExclude = @(
    "input.odin", "scene.odin",
    "main_client.odin", "client_renderer.odin", "client_audio.odin", "main_server.odin", "server.odin", "bots.odin",
    "main_combat_test.odin",
    "postgres.odin", "persistence.odin"
)

function Stage-Sources {
    param([string]$Dest, [string[]]$Exclude, [string]$RenameFrom, [string]$RenameTo)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Get-ChildItem -Path $SrcDir -Filter "*.odin" -File | ForEach-Object {
        if ($Exclude -contains $_.Name) { return }
        Copy-Item $_.FullName (Join-Path $Dest $_.Name)
    }
    if ($RenameFrom -and $RenameTo) {
        Move-Item -Force (Join-Path $Dest $RenameFrom) (Join-Path $Dest $RenameTo)
    }
}

$fail = 0

Write-Host ">> Checking headless server..."
$srv = Join-Path $Stage "server"
Stage-Sources -Dest $srv -Exclude $serverExclude -RenameFrom "main_server.odin" -RenameTo "main.odin"
& $Odin check $srv
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ">> Checking graphical client..."
$cli = Join-Path $Stage "client"
Stage-Sources -Dest $cli -Exclude $clientExclude
& $Odin check $cli "-collection:sokol=$Sokol" "-collection:game=$Root"
if ($LASTEXITCODE -ne 0) { $fail = 1 }

Write-Host ">> Checking headless test client..."
$tc = Join-Path $Stage "testclient"
Stage-Sources -Dest $tc -Exclude $testClientExclude -RenameFrom "main_test_client.odin" -RenameTo "main.odin"
& $Odin check $tc
if ($LASTEXITCODE -ne 0) { $fail = 1 }

if ($fail -eq 0) { Write-Host ">> OK" } else { Write-Host ">> FAILED"; exit 1 }
