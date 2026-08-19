<#
.SYNOPSIS
    Package HeadTracking mod for release.

.DESCRIPTION
    Creates two distributable ZIP files:
      - HeadTracking-v<version>-installer.zip   - install.cmd + mod files (for GitHub Releases).
      - HeadTracking-v<version>-nexus.zip       - deploy-subtree layout (extract into Cyberpunk 2077 root).

.PARAMETER Version
    Optional version string (e.g., "1.0.0"). Defaults to git describe output.

.EXAMPLE
    .\package-release.ps1
    .\package-release.ps1 -Version "1.0.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Fail {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

Import-Module (Join-Path $projectRoot "cameraunlock-core\powershell\ReleaseWorkflow.psm1") -Force

Set-Location $projectRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  HeadTracking Release Packaging" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

if (-not $Version) {
    # Canonical version source: scripts/install.cmd MOD_VERSION line.
    # Falls back to git describe so a CI build off a feature branch still
    # produces a usable -dev<short-sha> ZIP.
    $installCmdPath = Join-Path $projectRoot 'scripts/install.cmd'
    if (Test-Path $installCmdPath) {
        $installRaw = [System.IO.File]::ReadAllText($installCmdPath)
        if ($installRaw -match 'set "MOD_VERSION=([^"]+)"') {
            $Version = $matches[1]
        }
    }
    if (-not $Version) {
        try {
            $Version = git describe --tags --always 2>$null
            if (-not $Version) { $Version = 'dev' }
        } catch {
            $Version = 'dev'
        }
        $Version = $Version.TrimStart('v')
    }
}

Write-Info "Version: $Version"
Write-Info "Project root: $projectRoot"

# --- Required / optional mod files -----------------------------------------
# Must mirror the safeRequire() set in init.lua. Drift here ships a ZIP
# that loads with a missing-module error in the CET console.
$requiredModFiles = @(
    "init.lua",
    "modules\udp.lua",
    "modules\camera.lua",
    "modules\settings.lua",
    "modules\state.lua",
    "modules\ui.lua",
    "modules\GameUI.lua",
    "modules\builtin_crosshair.lua",
    "modules\aim.lua",
    "modules\nativesettings.lua",
    "modules\perf.lua",
    "modules\debuglog.lua",
    "modules\hotkeys.lua",
    "modules\poseinterpolator.lua"
)

$docFiles = @(
    "README.md",
    "LICENSE",
    "CHANGELOG.md",
    "THIRD-PARTY-NOTICES.md"
)

$installerScripts = @(
    "scripts\install.cmd",
    "scripts\uninstall.cmd",
    "scripts\deploy.ps1",
    "scripts\uninstall.ps1"
)

$nativeDll = "native\build\bin\HeadTrackingAim.dll"

# --- Validate --------------------------------------------------------------
Write-Info "Validating required files..."
foreach ($file in $requiredModFiles) {
    $fullPath = Join-Path $projectRoot $file
    if (-not (Test-Path $fullPath)) { Write-Fail "Missing required file: $file" }
    Write-Host "  [OK] $file" -ForegroundColor Green
}

foreach ($file in $installerScripts) {
    $fullPath = Join-Path $projectRoot $file
    if (-not (Test-Path $fullPath)) { Write-Fail "Missing required installer script: $file" }
}

$nativeDllPath = Join-Path $projectRoot $nativeDll
$hasNative = Test-Path $nativeDllPath
if ($hasNative) {
    Write-Info "Native plugin present - will be bundled: $nativeDll"
} else {
    Write-Info "Native plugin NOT built - Lua-only ZIPs will be produced. Run 'pixi run build-native' to include aim compensation."
}

# --- Prepare dist/ ---------------------------------------------------------
$distDir = Join-Path $projectRoot "dist"
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

$releaseDir = Join-Path $projectRoot "release"
if (-not (Test-Path $releaseDir)) { New-Item -ItemType Directory -Path $releaseDir -Force | Out-Null }

# --- Helper: copy the mod tree into a given "HeadTracking" target dir ------
# Copy init.lua + the whole modules/ tree, identical to deploy.ps1. Copying
# the directory wholesale (rather than an enumerated list) guarantees the
# ZIP carries exactly what `pixi run install` deploys - no drift when a new
# module is added.
function Copy-ModTree {
    param([string]$ModTargetDir)

    New-Item -ItemType Directory -Path $ModTargetDir -Force | Out-Null

    Copy-Item -Path (Join-Path $projectRoot "init.lua") -Destination (Join-Path $ModTargetDir "init.lua") -Force
    Copy-Item -Path (Join-Path $projectRoot "modules") -Destination (Join-Path $ModTargetDir "modules") -Recurse -Force

    # MIT requires the licence text to travel with the code. The Nexus ZIP
    # carries no root-level docs, so the notices ride inside the mod folder
    # where they cannot litter the game root.
    foreach ($n in @('LICENSE', 'THIRD-PARTY-NOTICES.md')) {
        Copy-Item -Path (Join-Path $projectRoot $n) -Destination (Join-Path $ModTargetDir $n) -Force
    }
}

# --- Build installer staging -----------------------------------------------
# Layout mirrors the repo checkout so scripts/deploy.ps1 (which is what
# install.cmd delegates to) finds everything at the same relative paths it
# does in development. That way `pixi run install` (from a clone) and
# extracting the installer ZIP + running install.cmd use the exact same
# deploy code path - including the CET bindings.json merge.
#
#   HeadTracking-installer/
#   |-- install.cmd, uninstall.cmd          (wrappers at root)
#   |-- init.lua, modules/                  (mod files flat, like the repo)
#   |-- scripts/deploy.ps1, uninstall.ps1, install.cmd, uninstall.cmd
#   |-- native/build/bin/HeadTrackingAim.dll  (same relpath as dev build)
#   `-- README.md / CHANGELOG.md / THIRD-PARTY-NOTICES.md
Write-Host ""
Write-Info "Staging installer ZIP..."
$installerStaging = Join-Path $distDir "HeadTracking-installer"
if (Test-Path $installerStaging) { Remove-Item -Path $installerStaging -Recurse -Force }
New-Item -ItemType Directory -Path $installerStaging -Force | Out-Null

# Mod files flat at installer root (init.lua + modules/)
Copy-ModTree -ModTargetDir $installerStaging

# Native DLL at the path deploy.ps1 looks for: native/build/bin/HeadTrackingAim.dll
if ($hasNative) {
    $installerDllDir = Join-Path $installerStaging "native\build\bin"
    New-Item -ItemType Directory -Path $installerDllDir -Force | Out-Null
    Copy-Item -Path $nativeDllPath -Destination (Join-Path $installerDllDir "HeadTrackingAim.dll") -Force
}

# Vendored loaders (CET + RED4ext) at the path launcher-manifest.json references
# (vendor/<slug>/<slug>.zip). The launcher extracts these; the legacy install.cmd
# path (deploy.ps1) reads them from the same place. The ZIP is the offline,
# self-contained source of truth - install never reaches the network.
foreach ($loader in @('cet', 'red4ext', 'tweakxl')) {
    $loaderZip = Join-Path $projectRoot "vendor\$loader\$loader.zip"
    if (-not (Test-Path $loaderZip)) {
        Write-Fail "Missing vendored loader vendor\$loader\$loader.zip - run 'pixi run update-deps' first."
    }
    $loaderDest = Join-Path $installerStaging "vendor\$loader"
    New-Item -ItemType Directory -Path $loaderDest -Force | Out-Null
    Copy-Item -Path $loaderZip -Destination (Join-Path $loaderDest "$loader.zip") -Force

    # LICENSE ships beside the loader zip: CET, RED4ext and TweakXL are all MIT
    # and redistributing the binary without the licence text is a licence
    # violation, not a tidiness nit. README.md carries the upstream tag / SHA-256
    # so a user can verify the bytes they were shipped.
    foreach ($attribution in @('LICENSE', 'README.md')) {
        $src = Join-Path $projectRoot "vendor\$loader\$attribution"
        if (-not (Test-Path $src)) {
            Write-Fail "Missing vendor\$loader\$attribution - run 'pixi run update-deps' first."
        }
        Copy-Item -Path $src -Destination (Join-Path $loaderDest $attribution) -Force
    }
}

# TweakDB tweaks. The projectile restoration lives here and is what makes
# automatic fire decouple, so a ZIP without it installs a mod that silently
# reverts to firing at screen centre.
$tweakSrc = Join-Path $projectRoot "tweaks"
if (-not (Test-Path $tweakSrc)) {
    Write-Fail "Missing tweaks/ - the projectile restoration is required for aim decoupling."
}
Copy-Item -Path $tweakSrc -Destination (Join-Path $installerStaging "tweaks") -Recurse -Force

# Scripts dir - identical to repo's scripts/ so deploy.ps1 resolves sourceDir correctly.
$installerScriptsDir = Join-Path $installerStaging "scripts"
New-Item -ItemType Directory -Path $installerScriptsDir -Force | Out-Null
foreach ($s in $installerScripts) {
    Copy-Item -Path (Join-Path $projectRoot $s) -Destination (Join-Path $installerScriptsDir (Split-Path -Leaf $s)) -Force
}
# Convenience root-level install.cmd / uninstall.cmd wrappers that delegate
# to scripts/*.ps1 - lets users double-click from the ZIP root.
Copy-Item -Path (Join-Path $projectRoot "scripts\install.cmd")   -Destination (Join-Path $installerStaging "install.cmd")   -Force
Copy-Item -Path (Join-Path $projectRoot "scripts\uninstall.cmd") -Destination (Join-Path $installerStaging "uninstall.cmd") -Force

foreach ($d in $docFiles) {
    $src = Join-Path $projectRoot $d
    if (Test-Path $src) { Copy-Item -Path $src -Destination (Join-Path $installerStaging (Split-Path -Leaf $d)) -Force }
}

# Stamp launcher-manifest.json with the real release version and drop it at the
# installer ZIP root. This is the file Lopari reads to ingest the package; the
# committed copy carries the placeholder 0.0.0 and the packager overwrites
# mod_info.version with the version actually being released.
$manifestSource = Join-Path $projectRoot "launcher-manifest.json"
if (-not (Test-Path $manifestSource)) { Write-Fail "Missing launcher-manifest.json at project root" }
$manifest = Get-Content -Path $manifestSource -Raw | ConvertFrom-Json
$manifest.mod_info.version = $Version
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path (Join-Path $installerStaging "launcher-manifest.json") -Encoding UTF8
Write-Info "Stamped launcher-manifest.json (mod_info.version=$Version)"

# Bundle the shared detection bundle (find-game.ps1 + games.json) so the root
# install.cmd's shim resolves at user-install time without a network round-trip.
Copy-SharedBundle -StagingDir $installerStaging -CoreRoot (Join-Path $projectRoot 'cameraunlock-core')

# --- Build Nexus staging ---------------------------------------------------
Write-Info "Staging Nexus (extract-to-game-root) ZIP..."
$nexusStaging = Join-Path $distDir "HeadTracking-nexus"
if (Test-Path $nexusStaging) { Remove-Item -Path $nexusStaging -Recurse -Force }
New-Item -ItemType Directory -Path $nexusStaging -Force | Out-Null

# bin/x64/plugins/cyber_engine_tweaks/mods/HeadTracking/...
$nexusModParent = Join-Path $nexusStaging "bin\x64\plugins\cyber_engine_tweaks\mods"
New-Item -ItemType Directory -Path $nexusModParent -Force | Out-Null
Copy-ModTree -ModTargetDir (Join-Path $nexusModParent "HeadTracking")

if ($hasNative) {
    $nexusRed4extDir = Join-Path $nexusStaging "red4ext\plugins"
    New-Item -ItemType Directory -Path $nexusRed4extDir -Force | Out-Null
    Copy-Item -Path $nativeDllPath -Destination (Join-Path $nexusRed4extDir "HeadTrackingAim.dll") -Force
}

# The projectile restoration must ship here too. Nexus users extract to the game
# root and manage their own loaders, but this tweak is mod content, not a loader:
# without it automatic fire silently reverts to landing at screen centre, which
# reads as "the mod is broken" rather than "a file is missing".
$nexusTweakDir = Join-Path $nexusStaging "r6\tweaks"
New-Item -ItemType Directory -Path $nexusTweakDir -Force | Out-Null
Get-ChildItem -Path (Join-Path $projectRoot "tweaks") -Filter *.yaml -File | ForEach-Object {
    Copy-Item -Path $_.FullName -Destination (Join-Path $nexusTweakDir $_.Name) -Force
}

# No docs / scripts in the Nexus ZIP - Nexus extracts straight into the
# game root, so anything outside the deploy subtree would litter the user's
# install. README/CHANGELOG live on the Nexus mod page, not in the ZIP.

# --- Zip both --------------------------------------------------------------
$installerZip = Join-Path $releaseDir "HeadTracking-v$Version-installer.zip"
$nexusZip     = Join-Path $releaseDir "HeadTracking-v$Version-nexus.zip"

foreach ($z in @($installerZip, $nexusZip)) {
    if (Test-Path $z) { Remove-Item -Path $z -Force }
}

# Not Compress-Archive: on Windows PowerShell 5.1 it writes entry names with
# backslash separators, which the ZIP spec (APPNOTE 4.4.17.1) says must be
# forward slashes. Windows Explorer, 7-Zip and Expand-Archive all cope, but
# mod managers and any non-Windows tool are not obliged to, and a Nexus ZIP
# gets opened by whatever the user happens to have.
function New-ZipFromDirectory {
    param([string]$SourceDir, [string]$ZipPath)

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $base = (Resolve-Path $SourceDir).Path.TrimEnd('\') + '\'
    $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        foreach ($file in (Get-ChildItem -Path $SourceDir -Recurse -File)) {
            $entryName = $file.FullName.Substring($base.Length) -replace '\\', '/'
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $file.FullName, $entryName,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    }
    finally {
        $zip.Dispose()
    }
}

Write-Info "Creating installer ZIP..."
New-ZipFromDirectory -SourceDir $installerStaging -ZipPath $installerZip

Write-Info "Creating Nexus ZIP..."
New-ZipFromDirectory -SourceDir $nexusStaging -ZipPath $nexusZip

# --- Clean up staging ------------------------------------------------------
Remove-Item -Path $installerStaging -Recurse -Force
Remove-Item -Path $nexusStaging     -Recurse -Force

function Format-ZipSize {
    param([string]$Path)
    $bytes = (Get-Item $Path).Length
    $kb = [math]::Round($bytes / 1024, 2)
    if ($kb -gt 1024) { "$([math]::Round($kb / 1024, 2)) MB" } else { "$kb KB" }
}

Write-Host ""
Write-Success "Release ZIPs created."
Write-Host ""
Write-Host "  Installer : $installerZip ($(Format-ZipSize $installerZip))"
Write-Host "  Nexus     : $nexusZip ($(Format-ZipSize $nexusZip))"
Write-Host ""
Write-Host "Installer usage : extract, run install.cmd." -ForegroundColor Yellow
Write-Host "Nexus usage     : extract directly into the Cyberpunk 2077 folder." -ForegroundColor Yellow
Write-Host ""

exit 0
