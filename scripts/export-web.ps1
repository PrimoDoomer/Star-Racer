<#
.SYNOPSIS
  Export the Godot client to a static HTML5/Web build (Windows / PowerShell).

.DESCRIPTION
  PowerShell counterpart of scripts/export-web.sh. Resolves a Godot 4 binary
  (GODOT_BIN env, then PATH, otherwise downloads a win64 build for the requested
  version), ensures the matching WEB export templates are installed (only the
  web templates — the official .tpz bundles every platform), then imports the
  project and exports the "Web" preset.

  Environment overrides:
    GODOT_BIN        Path to a Godot 4 executable. If unset, uses godot/godot4
                     from PATH, otherwise downloads a win64 build.
    GODOT_VERSION    Godot release to download/match (default: 4.6.3-stable).
                     Export templates MUST match the editor version exactly.
    OUT              Output directory (default: <repo>\build\web). The -OutDir
                     parameter takes precedence.
    STAR_RACER_CACHE Disk dir for the downloaded binary + template bundle
                     (default: %LOCALAPPDATA%\star-racer-godot).
    TEMPLATES_DIR    Override the export-templates install dir
                     (default: %APPDATA%\Godot\export_templates\<version>).

  After exporting, serve the folder over HTTP, e.g.:
    python -m http.server --directory build\web 8000
  The "Web" preset is single-threaded (thread_support=false), so no special
  COOP/COEP cross-origin-isolation headers are required.

.PARAMETER OutDir
  Output directory for the build (default: <repo>\build\web).
#>
[CmdletBinding()]
param(
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$GodotVersion = if ($env:GODOT_VERSION) { $env:GODOT_VERSION } else { '4.6.3-stable' }
$Preset = 'Web'

$RepoRoot  = Split-Path -Parent $PSScriptRoot
$ClientDir = Join-Path $RepoRoot 'client'
if (-not $OutDir) { $OutDir = if ($env:OUT) { $env:OUT } else { Join-Path $RepoRoot 'build\web' } }

$CacheDir = if ($env:STAR_RACER_CACHE) { $env:STAR_RACER_CACHE } else { Join-Path $env:LOCALAPPDATA 'star-racer-godot' }

# Templates version folder uses dots, e.g. "4.6.3-stable" -> "4.6.3.stable".
$DotVer = $GodotVersion -replace '-', '.'
$TemplatesDir = if ($env:TEMPLATES_DIR) { $env:TEMPLATES_DIR } else { Join-Path $env:APPDATA "Godot\export_templates\$DotVer" }

# Logs go through Write-Host (host stream), so they never end up in a function's
# pipeline return value.
function Log($msg) { Write-Host "[export-web] $msg" }
function Die($msg) { Write-Host "[export-web] ERROR: $msg" -ForegroundColor Red; exit 1 }

if (-not (Test-Path (Join-Path $ClientDir 'project.godot'))) {
    Die "client\project.godot not found (expected at '$ClientDir')"
}

# --- Resolve a Godot binary --------------------------------------------------
function Resolve-Godot {
    if ($env:GODOT_BIN -and (Test-Path $env:GODOT_BIN)) { return $env:GODOT_BIN }
    foreach ($c in 'godot', 'godot4', 'Godot') {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    # Download a win64 build into the cache.
    $zip        = "Godot_v${GodotVersion}_win64.exe.zip"
    $exe        = Join-Path $CacheDir "Godot_v${GodotVersion}_win64.exe"
    $consoleExe = Join-Path $CacheDir "Godot_v${GodotVersion}_win64_console.exe"
    if (-not (Test-Path $exe)) {
        New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
        Log "Downloading Godot $GodotVersion ..."
        $url  = "https://github.com/godotengine/godot/releases/download/$GodotVersion/$zip"
        $dest = Join-Path $CacheDir $zip
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        Expand-Archive -Path $dest -DestinationPath $CacheDir -Force
    }
    # The console build attaches to the terminal so headless output is visible.
    if (Test-Path $consoleExe) { return $consoleExe }
    return $exe
}

$Godot = Resolve-Godot
Log "Using Godot: $Godot"

# --- Ensure WEB export templates --------------------------------------------
# The official .tpz contains EVERY platform (android, ios, macos, windows,
# linux, web). Extract only the web templates so no iOS/Android/desktop files
# get installed. Copying every "web*" entry also covers whichever variant the
# preset needs (extensions_support=true + thread_support=false -> dlink/nothreads).
New-Item -ItemType Directory -Force -Path $TemplatesDir | Out-Null
$haveWeb = Get-ChildItem -Path $TemplatesDir -Filter 'web*' -File -ErrorAction SilentlyContinue
if ($haveWeb) {
    Log "Web export templates present at $TemplatesDir"
} else {
    Log "Web export templates for $DotVer not found - installing into $TemplatesDir"
    $tpz = Join-Path $CacheDir "Godot_v${GodotVersion}_export_templates.tpz"
    New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
    if (-not (Test-Path $tpz)) {
        $url = "https://github.com/godotengine/godot/releases/download/$GodotVersion/Godot_v${GodotVersion}_export_templates.tpz"
        Invoke-WebRequest -Uri $url -OutFile $tpz -UseBasicParsing
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [System.IO.Compression.ZipFile]::OpenRead($tpz)
    try {
        $count = 0
        foreach ($entry in $archive.Entries) {
            $name = $entry.Name  # bare filename ("" for directory entries)
            if ($entry.FullName -like 'templates/*' -and $name -and ($name -like 'web*' -or $name -eq 'version.txt')) {
                $target = Join-Path $TemplatesDir $name
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                if ($name -like 'web*') { $count++ }
            }
        }
        if ($count -eq 0) { Die "no web templates in bundle (unexpected .tpz layout)" }
    } finally {
        $archive.Dispose()
    }
    Log "Web templates installed (other platforms skipped)."
}

# --- Import + export ---------------------------------------------------------
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$indexPath = Join-Path $OutDir 'index.html'

Log "Importing project (headless) ..."
Push-Location $ClientDir
try {
    & $Godot --headless --import   # may exit non-zero on first import; that's fine

    Log "Exporting preset '$Preset' -> $indexPath"
    & $Godot --headless --export-release $Preset $indexPath
    $exportExit = $LASTEXITCODE
} finally {
    Pop-Location
}

if (-not (Test-Path $indexPath)) {
    Die "export did not produce index.html (godot exit $exportExit - check the log above)"
}

Log "Done. Build in: $OutDir"
Log "Serve it with:  python -m http.server --directory `"$OutDir`" 8000"
