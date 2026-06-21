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

# Kill-on-close job object: when THIS pwsh process disappears for any reason
# (Ctrl+C, terminal window closed, taskkill, crash), Windows closes the job
# handle and the OS kills every assigned child. This is the only way to
# guarantee no orphaned server holds :8080 after the launcher is gone — the
# finally/Stop-All block only runs on graceful exits.
if (-not ('Win32Job' -as [type])) {
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class Win32Job
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateJobObject(IntPtr a, string n);
    [DllImport("kernel32.dll")]
    static extern bool SetInformationJobObject(IntPtr h, int c, IntPtr i, uint l);
    [DllImport("kernel32.dll")]
    static extern bool AssignProcessToJobObject(IntPtr h, IntPtr p);

    const int ExtendedLimitInformation = 9;
    const uint KILL_ON_JOB_CLOSE = 0x2000;

    [StructLayout(LayoutKind.Sequential)]
    struct BASIC { public long a; public long b; public uint LimitFlags;
        public UIntPtr c; public UIntPtr d; public uint e; public UIntPtr f;
        public uint g; public uint h; }
    [StructLayout(LayoutKind.Sequential)]
    struct IOC { public ulong a, b, c, d, e, f; }
    [StructLayout(LayoutKind.Sequential)]
    struct EXT { public BASIC Basic; public IOC Io; public UIntPtr a, b, c, d; }

    public static IntPtr CreateKillOnClose()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        var ext = new EXT();
        ext.Basic.LimitFlags = KILL_ON_JOB_CLOSE;
        int len = Marshal.SizeOf(ext);
        IntPtr p = Marshal.AllocHGlobal(len);
        try {
            Marshal.StructureToPtr(ext, p, false);
            if (!SetInformationJobObject(job, ExtendedLimitInformation, p, (uint)len))
                throw new System.ComponentModel.Win32Exception();
        } finally { Marshal.FreeHGlobal(p); }
        return job;
    }

    public static void Assign(IntPtr job, IntPtr proc)
    {
        if (!AssignProcessToJobObject(job, proc))
            throw new System.ComponentModel.Win32Exception();
    }
}
'@
}
$JobHandle = [Win32Job]::CreateKillOnClose()

# Assign a started process to the kill-on-close job. A failure here is not fatal:
# Stop-All still handles graceful exits, the job is only the hard-kill safety net.
function Add-ToJob($proc) {
    if (-not $proc) { return }
    try { [Win32Job]::Assign($JobHandle, $proc.Handle) }
    catch { Write-Host "[run-all] WARNING: could not add PID $($proc.Id) to kill-on-close job: $_" -ForegroundColor Yellow }
}

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

    # Free :8080 if a previous run left a server behind — but ONLY if the holder
    # is one of our own freshly built binaries. 8080 is a common dev port, so a
    # foreign holder is left untouched and we abort rather than risk killing an
    # unrelated process.
    $ownExes = @("$ServerDir\target\$target\server.exe", "$ServerDir\target\$target\bots.exe") |
        ForEach-Object { (Resolve-Path $_ -ErrorAction SilentlyContinue).Path } | Where-Object { $_ }
    $holders = Get-NetTCPConnection -LocalPort 8080 -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
    foreach ($holderPid in $holders) {
        $hp = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        $hpath = if ($hp -and $hp.Path) { (Resolve-Path $hp.Path -ErrorAction SilentlyContinue).Path } else { $null }
        if ($hpath -and ($ownExes -contains $hpath)) {
            Write-Host "[run-all] Freeing :8080 — killing our own stale $($hp.Name) (PID $holderPid)" -ForegroundColor Yellow
            Stop-Process -Id $holderPid -Force -ErrorAction SilentlyContinue
        } else {
            $who = if ($hp) { "$($hp.Name) ($hpath)" } else { "PID $holderPid" }
            Write-Host "[run-all] ERROR: port 8080 is held by a process that isn't ours: $who. Refusing to kill it — free the port and retry." -ForegroundColor Red
            exit 1
        }
    }

    Write-Host "[run-all] Starting server…"
    $srvOut = [System.IO.Path]::GetTempFileName()
    $srvErr = [System.IO.Path]::GetTempFileName()
    $serverProc = Start-Process -FilePath "$ServerDir\target\$target\server.exe" `
        -WorkingDirectory $ServerDir -PassThru -NoNewWindow `
        -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
    $procs += $serverProc
    Add-ToJob $serverProc

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
    $botsProc = Start-Process -FilePath "$ServerDir\target\$target\bots.exe" `
        -WorkingDirectory $ServerDir -PassThru -WindowStyle Hidden
    $procs += $botsProc
    Add-ToJob $botsProc

    $botWarmup = if ($env:BOT_WARMUP) { [int]$env:BOT_WARMUP } else { 2 }
    Write-Host "[run-all] Letting bots settle for ${botWarmup}s…"
    Start-Sleep -Seconds $botWarmup

    Write-Host "[run-all] Starting Godot client ($GodotBin)…"
    try {
        $godotProc = Start-Process -FilePath $GodotBin -ArgumentList @('--path', $ClientDir) `
            -WorkingDirectory $ClientDir -PassThru -ErrorAction Stop
        $procs += $godotProc
        Add-ToJob $godotProc
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
