param(
    [ValidateSet("server", "client", "testclient", "both")]
    [string]$Target = "both",
    [switch]$Run,
    [switch]$Release,
    [switch]$StageOnly
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
$SrcDir = Join-Path $Root "src"

if (-not $StageOnly -and -not (Test-Path $Odin)) {
    Write-Error "Odin not found at $Odin. Set ODIN_ROOT or install to C:\Users\lusr\tools\odin"
}
$needsSokol = -not $StageOnly -and ($Target -eq "client" -or $Target -eq "both")
if ($needsSokol -and -not (Test-Path $Sokol)) {
    Write-Error "sokol-odin missing. Copy yearning/third_party/sokol-odin into third_party/ or run third_party\build_sokol_d3d11.cmd"
}
if ($StageOnly -and $Target -ne "server") {
    Write-Error "-StageOnly is only valid with -Target server"
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$modeArgs = @()
if ($Release) {
    $modeArgs += "-o:speed"
} else {
    $modeArgs += "-debug"
}

# Each target is the shared game code in src\*.odin plus its own folders.
# Keep in sync with .github/scripts/release-build.sh.
function Copy-StagedSources {
    param(
        [string]$Dest,
        [string[]]$Dirs
    )

    if (Test-Path $Dest) {
        Remove-Item -Recurse -Force $Dest
    }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null

    foreach ($dir in @($SrcDir) + @($Dirs | ForEach-Object { Join-Path $SrcDir $_ })) {
        Get-ChildItem -Path $dir -Filter "*.odin" -File | ForEach-Object {
            Copy-Item $_.FullName (Join-Path $Dest $_.Name)
        }
    }
}

function Build-OdinPackage {
    param(
        [string]$PackageDir,
        [string]$OutFile,
        [string[]]$ExtraArgs
    )

    $odinArgs = @(
        "build", $PackageDir,
        "-out:$OutFile"
    ) + $ExtraArgs + $modeArgs

    & $Odin @odinArgs
    if ($LASTEXITCODE -ne 0) {
        exit $LASTEXITCODE
    }
    if (-not (Test-Path $OutFile)) {
        Write-Error "Odin reported success but did not write $OutFile"
    }
}

if ($Target -eq "server" -or $Target -eq "both") {
    Write-Host ">> Staging headless server sources..."
    $tmp = Join-Path $OutDir "server_src"
    Copy-StagedSources -Dest $tmp -Dirs @("server")
    if ($StageOnly) {
        Write-Host ">> Staged $tmp"
        return
    }
    Write-Host ">> Building headless server..."
    $serverOut = Join-Path $OutDir "nexus_server.exe"
    Build-OdinPackage -PackageDir $tmp -OutFile $serverOut -ExtraArgs @()
    Remove-Item -Recurse -Force $tmp
    Write-Host ">> Built $serverOut"
}

if ($Target -eq "client" -or $Target -eq "both") {
    $shaderSrc = Join-Path $Root "shaders\scene.glsl"
    $shaderOut = Join-Path $SrcDir "client/sokol/scene.odin"
    $needShader = -not (Test-Path $shaderOut)
    if (-not $needShader -and (Test-Path $shaderSrc)) {
        $needShader = (Get-Item $shaderSrc).LastWriteTime -gt (Get-Item $shaderOut).LastWriteTime
    }
    if ($needShader) {
        if (-not (Test-Path $Shdc)) {
            Write-Error "sokol-shdc not found at $Shdc"
        }
        Write-Host ">> Compiling shaders..."
        & $Shdc `
            -i $shaderSrc `
            -o $shaderOut `
            -l hlsl5:glsl430:metal_macos:wgsl `
            -f sokol_odin
        if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    } else {
        Write-Host ">> Shaders up to date"
    }

    Write-Host ">> Building graphical client..."
    $tmp = Join-Path $OutDir "gfx_client_src"
    Copy-StagedSources -Dest $tmp -Dirs @("client", "client/sokol")
    Build-OdinPackage -PackageDir $tmp -OutFile (Join-Path $OutDir "nexus_client.exe") -ExtraArgs @("-collection:sokol=$Sokol", "-collection:game=$Root")
    Remove-Item -Recurse -Force $tmp
    Write-Host ">> Built $(Join-Path $OutDir 'nexus_client.exe')"
}

if ($Target -eq "testclient") {
    Write-Host ">> Building headless test client..."
    $tmp = Join-Path $OutDir "client_src"
    Copy-StagedSources -Dest $tmp -Dirs @("test_client")
    Build-OdinPackage -PackageDir $tmp -OutFile (Join-Path $OutDir "nexus_client_test.exe")
    Remove-Item -Recurse -Force $tmp
    Write-Host ">> Built $(Join-Path $OutDir 'nexus_client_test.exe')"
}

Write-Host ""
Write-Host "Playtest:"
Write-Host "  .\bin\nexus_client.exe              # defaults to primord.io:27015"
Write-Host "  `$env:SERVER_IP = '127.0.0.1'       # local dedicated server"
Write-Host "  .\bin\nexus_server.exe"

if ($Run) {
    if ($Target -eq "client") {
        & (Join-Path $OutDir "nexus_client.exe")
    } elseif ($Target -eq "testclient") {
        & (Join-Path $OutDir "nexus_client_test.exe")
    } else {
        & (Join-Path $OutDir "nexus_server.exe")
    }
}
