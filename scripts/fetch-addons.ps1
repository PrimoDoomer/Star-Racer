# Download Godot addons listed in scripts/addons.lock into Client/addons/.
# Idempotent: skips an addon if its installed version matches the lock file.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$LockFile   = Join-Path $PSScriptRoot 'addons.lock'
$AddonsDir  = Join-Path $RepoRoot 'Client/addons'
$StampName  = '.addon-version'

if (-not (Test-Path $AddonsDir)) { New-Item -ItemType Directory -Path $AddonsDir | Out-Null }

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("star-racer-addons-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpRoot | Out-Null

try {
    foreach ($line in Get-Content $LockFile) {
        $trim = $line.Trim()
        if ($trim -eq '' -or $trim.StartsWith('#')) { continue }

        $parts = $trim -split '\s+', 4
        if ($parts.Count -lt 4) { throw "Bad lock line: $line" }
        $addonId, $repo, $tag, $assetName = $parts

        $target   = Join-Path $AddonsDir $addonId
        $stamp    = Join-Path $target $StampName
        $expected = "$repo@$tag@$assetName"

        if ((Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $expected)) {
            Write-Host "[=] $addonId already at $tag"
            continue
        }

        $url = "https://github.com/$repo/releases/download/$tag/$assetName"
        Write-Host "[+] Fetching $addonId ($repo $tag)"
        Write-Host "    $url"

        $archive = Join-Path $tmpRoot "$addonId.zip"
        Invoke-WebRequest -Uri $url -OutFile $archive -UseBasicParsing

        $extract = Join-Path $tmpRoot "extract-$addonId"
        New-Item -ItemType Directory -Path $extract | Out-Null
        Expand-Archive -Path $archive -DestinationPath $extract -Force

        $src = Get-ChildItem -Path $extract -Recurse -Directory -Filter $addonId | Select-Object -First 1
        if (-not $src) { throw "Could not locate '$addonId' folder inside archive" }

        if (Test-Path $target) { Remove-Item -Recurse -Force $target }
        New-Item -ItemType Directory -Path $target | Out-Null
        Copy-Item -Path (Join-Path $src.FullName '*') -Destination $target -Recurse -Force

        Set-Content -Path $stamp -Value $expected -Encoding utf8
        Write-Host "    installed -> $target"
    }

    Write-Host 'Done.'
}
finally {
    Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
}
