# Launches the server, the bots, and the Godot client.
# Usage: pwsh scripts/run-all.ps1 [-Release]
#
# Override the Godot binary with the GODOT env var (default: "godot").
[CmdletBinding()]
param(
    [switch]$Release
)

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $RepoRoot 'server'
$ClientDir = Join-Path $RepoRoot 'client'
$GodotBin  = if ($env:GODOT) { $env:GODOT } else { 'godot' }

if (-not (Get-Command $GodotBin -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host "[run-all] ERROR: '$GodotBin' not found in PATH. Set `$env:GODOT to the full path of your Godot executable." -ForegroundColor Red
    exit 1
}

$target    = if ($Release) { 'release' } else { 'debug' }
$buildArgs = if ($Release) { @('build', '--release', '--bin', 'server', '--bin', 'bots') } `
                      else { @('build', '--bin', 'server', '--bin', 'bots') }

$procs = @()

function Stop-All {
    Write-Host "`n[run-all] Stopping child processes…"
    foreach ($p in $procs) {
        if ($p -and -not $p.HasExited) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
}

try {
    Write-Host "[run-all] Building binaries…"
    Push-Location $ServerDir
    try { & cargo @buildArgs } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    Write-Host "[run-all] Starting server…"
    $srvOut = [System.IO.Path]::GetTempFileName()
    $srvErr = [System.IO.Path]::GetTempFileName()
    $serverProc = Start-Process -FilePath "$ServerDir\target\$target\server.exe" `
        -WorkingDirectory $ServerDir -PassThru -NoNewWindow `
        -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
    $procs += $serverProc

    $shareRW = [System.IO.FileShare]::ReadWrite
    $outRdr = [System.IO.StreamReader]::new([System.IO.FileStream]::new($srvOut, 'Open', 'Read', $shareRW))
    $errRdr = [System.IO.StreamReader]::new([System.IO.FileStream]::new($srvErr, 'Open', 'Read', $shareRW))

    Write-Host "[run-all] Waiting for 'core loop spawned'…"
    $serverReady = $false
    $deadline = (Get-Date).AddSeconds(60)
    while (-not $serverReady -and (Get-Date) -lt $deadline) {
        foreach ($rdr in $outRdr, $errRdr) {
            $line = $rdr.ReadLine()
            while ($null -ne $line) {
                Write-Host $line
                if ($line -match 'core loop spawned') { $serverReady = $true }
                $line = $rdr.ReadLine()
            }
        }
        if (-not $serverReady) { Start-Sleep -Milliseconds 100 }
    }
    $outRdr.Close(); $errRdr.Close()
    if (-not $serverReady) {
        Write-Host "[run-all] WARNING: Ready signal not seen after 60 s, proceeding anyway." -ForegroundColor Yellow
    }

    Write-Host "[run-all] Starting bots…"
    $procs += Start-Process -FilePath "$ServerDir\target\$target\bots.exe" `
        -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden

    $botWarmup = if ($env:BOT_WARMUP) { [int]$env:BOT_WARMUP } else { 2 }
    Write-Host "[run-all] Letting bots settle for ${botWarmup}s…"
    Start-Sleep -Seconds $botWarmup

    Write-Host "[run-all] Starting Godot client ($GodotBin)…"
    try {
        $godotProc = Start-Process -FilePath $GodotBin -ArgumentList @('--path', $ClientDir) `
            -WorkingDirectory $ClientDir -PassThru -ErrorAction Stop
        $procs += $godotProc
        Start-Sleep -Seconds 2
        if ($godotProc.HasExited) {
            Write-Host "[run-all] ERROR: Godot exited immediately (code $($godotProc.ExitCode)). Run manually to diagnose: $GodotBin --path `"$ClientDir`"" -ForegroundColor Red
        }
    } catch {
        Write-Host "[run-all] ERROR: Failed to launch Godot: $_" -ForegroundColor Red
    }

    Write-Host "[run-all] All processes launched. Ctrl+C to stop."
    while ($true) {
        Start-Sleep -Seconds 1
        $alive = $procs | Where-Object { $_ -and -not $_.HasExited }
        if (-not $alive) { break }
    }
}
finally {
    Stop-All
}
