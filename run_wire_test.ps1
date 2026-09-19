# End-to-end check of the v9 protocol: a server, two named headless clients,
# and the roster/combat-log output they print. Builds into %TEMP% so it does
# not fight whatever is holding bin\.
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Odin = if ($env:ODIN_ROOT) { Join-Path $env:ODIN_ROOT "odin.exe" } else { "C:\Users\lusr\tools\odin\odin.exe" }
$SrcDir = Join-Path $Root "src"
$Stage = Join-Path $env:TEMP "nexus_wire"

$serverExclude = @(
    "input.odin", "scene.odin",
    "main_client.odin", "client_renderer.odin", "client_audio.odin", "main_test_client.odin", "main_combat_test.odin",
    "postgres.odin", "persistence.odin"
)
$testClientExclude = @(
    "input.odin", "scene.odin",
    "main_client.odin", "client_renderer.odin", "client_audio.odin", "main_server.odin", "server.odin", "bots.odin",
    "main_combat_test.odin",
    "postgres.odin", "persistence.odin"
)

# The dev box usually has a server already on 27015.
$env:NEXUS_PORT = "27115"

function Stage-Sources {
    param([string]$Dest, [string[]]$Exclude, [string]$RenameFrom, [string]$RenameTo)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Get-ChildItem -Path $SrcDir -Filter "*.odin" -File | ForEach-Object {
        if ($Exclude -contains $_.Name) { return }
        Copy-Item $_.FullName (Join-Path $Dest $_.Name)
    }
    Move-Item -Force (Join-Path $Dest $RenameFrom) (Join-Path $Dest $RenameTo)
}

New-Item -ItemType Directory -Force -Path $Stage | Out-Null
$serverBin = Join-Path $Stage "nexus_server.exe"
$clientBin = Join-Path $Stage "nexus_client_test.exe"

Write-Host ">> Building server..."
Stage-Sources -Dest (Join-Path $Stage "server") -Exclude $serverExclude -RenameFrom "main_server.odin" -RenameTo "main.odin"
& $Odin build (Join-Path $Stage "server") "-out:$serverBin" -o:minimal
if ($LASTEXITCODE -ne 0) { exit 1 }

Write-Host ">> Building test client..."
Stage-Sources -Dest (Join-Path $Stage "testclient") -Exclude $testClientExclude -RenameFrom "main_test_client.odin" -RenameTo "main.odin"
& $Odin build (Join-Path $Stage "testclient") "-out:$clientBin" -o:minimal
if ($LASTEXITCODE -ne 0) { exit 1 }

$srvLog = Join-Path $Stage "server.log"
$aLog = Join-Path $Stage "alice.log"
$bLog = Join-Path $Stage "bob.log"

Write-Host ">> Starting server..."
$env:BOTS_PER_TEAM = "2"
$env:NEXUS_VERBOSE = "true"
$srv = Start-Process -FilePath $serverBin -RedirectStandardOutput $srvLog -RedirectStandardError (Join-Path $Stage "server.err") -PassThru -WindowStyle Hidden
Start-Sleep -Seconds 2

Write-Host ">> Starting two named clients..."
$env:NEXUS_TEST_FIGHT = "1"
$env:NEXUS_TEST_NAME = "Alice the Bold"
$a = Start-Process -FilePath $clientBin -RedirectStandardOutput $aLog -RedirectStandardError (Join-Path $Stage "alice.err") -PassThru -WindowStyle Hidden
$env:NEXUS_TEST_NAME = "bob<script>"
$b = Start-Process -FilePath $clientBin -RedirectStandardOutput $bLog -RedirectStandardError (Join-Path $Stage "bob.err") -PassThru -WindowStyle Hidden

Write-Host ">> Running 32s..."
$a.WaitForExit(40000) | Out-Null
$b.WaitForExit(40000) | Out-Null
Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "================ SERVER ================"
Get-Content $srvLog -Tail 25
Write-Host ""
Write-Host "================ ALICE (final) ================"
Get-Content $aLog -Tail 30
Write-Host ""
Write-Host "================ BOB (final) ================"
Get-Content $bLog -Tail 30
