# Runs the whole test suite: Rust server tests + headless Godot client tests.
# Usage: pwsh scripts/run-tests.ps1
#
# Override the Godot binary with the GODOT env var (default: "godot").
# Exits non-zero if any suite fails.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$ServerDir = Join-Path $RepoRoot 'server'
$ClientDir = Join-Path $RepoRoot 'client'
$GodotBin  = if ($env:GODOT) { $env:GODOT } else { 'godot' }

Write-Host "[run-tests] Server (cargo test)…"
Push-Location $ServerDir
try { & cargo test } finally { Pop-Location }
if ($LASTEXITCODE -ne 0) { Write-Host "[run-tests] Server tests failed." -ForegroundColor Red; exit $LASTEXITCODE }

Write-Host "[run-tests] Client (Godot headless)…"
if (-not (Get-Command $GodotBin -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Host "[run-tests] ERROR: '$GodotBin' not found in PATH. Set `$env:GODOT to the full path of your Godot executable." -ForegroundColor Red
    exit 1
}
# First headless run imports assets (needed on a fresh checkout); ignore its code.
& $GodotBin --headless --path $ClientDir --import *> $null
& $GodotBin --headless --path $ClientDir --script res://tests/run_tests.gd
if ($LASTEXITCODE -ne 0) { Write-Host "[run-tests] Client tests failed." -ForegroundColor Red; exit $LASTEXITCODE }

Write-Host "[run-tests] All suites passed." -ForegroundColor Green
