<#
.SYNOPSIS
    Deploy HeadTracking mod to Cyberpunk 2077 CET mods directory.

.DESCRIPTION
    Validates game and CET installation, then copies mod files to the correct location.
    Without -GamePath, every installed copy of the game on this machine (Steam,
    GOG, Epic) is deployed to, and the outcome is reported per copy.

.PARAMETER GamePath
    Optional custom path to one Cyberpunk 2077 installation. When given, that
    copy is the only target.

.EXAMPLE
    .\deploy.ps1
    .\deploy.ps1 -GamePath "D:\Games\Cyberpunk 2077"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GamePath,

    # Non-interactive: never prompt. Set by install.cmd's /y and by the Lopari
    # launcher. An out-of-date loader is reported loudly and left alone, because
    # replacing a shared framework other mods depend on is not a decision to
    # take behind the user's back.
    [Parameter(Mandatory = $false)]
    [switch]$AssumeYes,

    # Replace an out-of-date loader with the bundled one without asking. The
    # non-interactive way to say yes to the upgrade prompt.
    [Parameter(Mandatory = $false)]
    [switch]$UpgradeLoaders
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Color output helpers
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Game-path detection delegates to the shared helper so it honors
# CYBERPUNK_2077_PATH env var, Steam appmanifest (1091500), Steam folder
# fallback, and GOG/Epic registry lookups - the same order install.cmd uses
# via find-game.ps1. Hardcoding a CommonPaths list here would drift from
# games.json on every new launcher / install layout.
$projectRootForDeploy = Split-Path -Parent $PSScriptRoot
# Source-tree layout: cameraunlock-core submodule sits at the project root.
# Lopari / release-package layout: GamePathDetection.psm1 is copied flat into
# shared/ by Copy-SharedBundle. Prefer the source path when present so local
# dev still picks up submodule changes; fall back to shared/ for packaged
# installs where the submodule was never shipped.
$gpdCandidates = @(
    (Join-Path $projectRootForDeploy 'cameraunlock-core/powershell/GamePathDetection.psm1'),
    (Join-Path $projectRootForDeploy 'shared/GamePathDetection.psm1')
)
$gpdPath = $gpdCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $gpdPath) {
    Write-Fail "Could not find GamePathDetection.psm1 in either cameraunlock-core/powershell/ or shared/."
    exit 1
}
Import-Module $gpdPath -Force

# Every installed copy, not the first one detection returns. Owning the game on
# two stores is ordinary, and a deploy that writes to one copy while the other
# gets launched presents as a fix that did not work. A caller-supplied path wins
# outright and stays a single target, because the launcher passes one and means
# it.
function Find-GameInstallations {
    param(
        [string]$CustomPath
    )

    if ($CustomPath) {
        $exePath = Join-Path $CustomPath 'bin\x64\Cyberpunk2077.exe'
        if ((Test-Path $CustomPath) -and (Test-Path $exePath)) { return @($CustomPath) }
        Write-Fail "Provided -GamePath does not contain Cyberpunk 2077: $CustomPath"
        exit 1
    }

    return @(Find-AllGamePaths -GameId 'cyberpunk-2077')
}

function Validate-CETInstallation {
    param(
        [string]$GameDir
    )

    $cetDir = Join-Path $GameDir "bin\x64\plugins\cyber_engine_tweaks"

    if (-not (Test-Path $cetDir)) {
        return $null
    }

    # Check for CET core file
    $cetCore = Join-Path $GameDir "bin\x64\plugins\cyber_engine_tweaks.asi"
    if (-not (Test-Path $cetCore)) {
        # Try alternate location
        $cetCore = Join-Path $GameDir "bin\x64\global.ini"
    }

    return $cetDir
}

function Validate-ModFiles {
    param(
        [string]$SourceDir
    )

    $requiredFiles = @(
        "init.lua",
        "modules\udp.lua",
        "modules\camera.lua",
        "modules\settings.lua",
        "modules\state.lua",
        "modules\ui.lua",
        "modules\GameUI.lua"
    )

    $missing = @()
    foreach ($file in $requiredFiles) {
        $fullPath = Join-Path $SourceDir $file
        if (-not (Test-Path $fullPath)) {
            $missing += $file
        }
    }

    return $missing
}

function Deploy-Mod {
    param(
        [string]$SourceDir,
        [string]$TargetDir
    )

    # Ensure target directory exists
    if (-not (Test-Path $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
        Write-Info "Created mod directory: $TargetDir"
    }

    # Copy init.lua
    $initSource = Join-Path $SourceDir "init.lua"
    $initTarget = Join-Path $TargetDir "init.lua"
    Copy-Item -Path $initSource -Destination $initTarget -Force
    Write-Info "Copied init.lua"

    # Copy modules directory
    $modulesSource = Join-Path $SourceDir "modules"
    $modulesTarget = Join-Path $TargetDir "modules"
    if (Test-Path $modulesTarget) {
        Remove-Item -Path $modulesTarget -Recurse -Force
    }
    Copy-Item -Path $modulesSource -Destination $modulesTarget -Recurse -Force
    Write-Info "Copied modules directory"

    # Licence and attribution travel with the deployed code, matching what the
    # launcher-manifest deploys and what the Nexus ZIP extracts.
    foreach ($n in @('LICENSE', 'THIRD-PARTY-NOTICES.md')) {
        Copy-Item -Path (Join-Path $SourceDir $n) -Destination (Join-Path $TargetDir $n) -Force
    }
    Write-Info "Copied LICENSE and THIRD-PARTY-NOTICES.md"

    return $true

}

function Deploy-NativePlugin {
    param(
        [string]$SourceDir,
        [string]$GameDir
    )

    # Only the canonical output of `pixi run build-native`. A second candidate
    # pointing at an old experiment directory meant a cleaned build\ silently
    # deployed a stale DLL from that directory instead of failing.
    $dllSource = Join-Path $SourceDir "native\build\bin\HeadTrackingAim.dll"
    if (-not (Test-Path $dllSource)) {
        Write-Info "Native plugin not built - skipping (run 'pixi run build-native' to build)"
        return $false
    }

    # Check for RED4ext installation
    $red4extDir = Join-Path $GameDir "red4ext\plugins"
    if (-not (Test-Path $red4extDir)) {
        # Check if RED4ext is installed at all
        $red4extCore = Join-Path $GameDir "red4ext"
        if (-not (Test-Path $red4extCore)) {
            Write-Info "RED4ext not installed - native aim compensation disabled"
            Write-Info "Install RED4ext from: https://github.com/WopsS/RED4ext/releases"
            return $false
        }
        # Create plugins directory
        New-Item -ItemType Directory -Path $red4extDir -Force | Out-Null
    }

    # Deploy the DLL
    $dllTarget = Join-Path $red4extDir "HeadTrackingAim.dll"
    Copy-Item -Path $dllSource -Destination $dllTarget -Force
    Write-Info "Deployed native plugin: $dllTarget"

    return $true
}

function Deploy-Tweaks {
    param(
        [string]$SourceDir,
        [string]$GameDir
    )

    $tweakSource = Join-Path $SourceDir "tweaks"
    if (-not (Test-Path $tweakSource)) {
        Write-Fail "tweaks/ not found at $tweakSource - the projectile restoration is missing."
        return $false
    }

    $tweakTarget = Join-Path $GameDir "r6\tweaks"
    New-Item -ItemType Directory -Path $tweakTarget -Force | Out-Null
    Get-ChildItem -Path $tweakSource -Filter *.yaml -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $tweakTarget $_.Name) -Force
        Write-Info "Deployed tweak: $($_.Name)"
    }
    return $true
}

# Version of an installed loader binary, from its Win32 version resource.
# Trimmed to major.minor.patch: TweakXL stamps a build number into the fourth
# field (1.11.3.2512252203) that overflows [version]'s Int32 revision.
function Get-InstalledLoaderVersion {
    param([string]$BinaryPath)

    if (-not (Test-Path -LiteralPath $BinaryPath)) { return $null }
    $raw = (Get-Item -LiteralPath $BinaryPath).VersionInfo.FileVersion
    if (-not $raw) { return $null }
    $parts = ($raw.Trim().TrimStart('v') -split '[.,]') | Where-Object { $_ -match '^\d+$' }
    if ($parts.Count -lt 2) { return $null }
    $take = [Math]::Min(3, $parts.Count)
    return [version](($parts[0..($take - 1)]) -join '.')
}

# Version of the loader we ship, read from the sidecar the vendoring step
# writes. Parsing the tag beats reading the zip: the sidecar is the same file
# that records the upstream URL and SHA-256 the bytes were fetched under.
function Get-VendoredLoaderVersion {
    param([string]$SourceDir, [string]$Slug)

    $readme = Join-Path $SourceDir "vendor\$Slug\README.md"
    if (-not (Test-Path -LiteralPath $readme)) { return $null }
    $line = Select-String -Path $readme -Pattern '^\s*-\s*Tag:\s*`?v?([0-9]+(\.[0-9]+)+)`?' | Select-Object -First 1
    if (-not $line) { return $null }
    $parts = ($line.Matches[0].Groups[1].Value -split '\.') | Where-Object { $_ -match '^\d+$' }
    $take = [Math]::Min(3, $parts.Count)
    return [version](($parts[0..($take - 1)]) -join '.')
}

function Install-VendoredLoader {
    param(
        [string]$SourceDir,
        [string]$GameDir,
        [string]$Slug,
        [string]$DetectRelPath,
        [string]$DisplayName
    )

    $detect = Join-Path $GameDir $DetectRelPath
    if (Test-Path $detect) {
        $installed = Get-InstalledLoaderVersion -BinaryPath (Join-Path $GameDir $DetectRelPath)
        $vendored  = Get-VendoredLoaderVersion -SourceDir $SourceDir -Slug $Slug

        if ($null -eq $installed -or $null -eq $vendored) {
            Write-Info "$DisplayName already present (version unreadable) - leaving the existing install untouched"
            return $true
        }
        if ($installed -ge $vendored) {
            Write-Info "$DisplayName $installed already present (bundled: $vendored) - leaving it untouched"
            return $true
        }

        # An out-of-date loader is the single most common reason a Cyberpunk mod
        # silently does nothing in game: the loader refuses to initialise on a
        # newer game build and every mod under it goes dark. Saying "already
        # present" and reporting success here is how that turns into a bug
        # report against us.
        Write-Host ""
        Write-Host "  !! $DisplayName $installed is OLDER than the bundled $vendored." -ForegroundColor Yellow
        Write-Host "     An out-of-date loader will not initialise on a current game build," -ForegroundColor Yellow
        Write-Host "     and every mod that depends on it - including this one - stays dark." -ForegroundColor Yellow

        if (-not ($UpgradeLoaders -or $AssumeYes)) {
            $answer = Read-Host "     Replace it with the bundled ${vendored}? [Y/n]"
            if ($answer -and $answer.Trim().ToLower().StartsWith('n')) {
                Write-Info "Leaving $DisplayName $installed in place at your request"
                return $true
            }
        }
        elseif (-not $UpgradeLoaders) {
            # Deliberately not upgrading unattended. Someone holding an older
            # game build on purpose runs the matching older loader, and taking
            # that away without asking breaks a working setup.
            Write-Host "     Not replacing it automatically. Re-run with /upgrade-deps to update it," -ForegroundColor Yellow
            Write-Host "     or install $DisplayName $vendored yourself." -ForegroundColor Yellow
            Write-Host ""
            return $true
        }
        Write-Host ""
    }

    # Vendored zip ships in the release ZIP at vendor\<slug>\<slug>.zip. Absent
    # only in a bare dev checkout (run 'pixi run update-deps'); fall through so
    # the caller's manual-install guidance still fires there.
    $zip = Join-Path $SourceDir "vendor\$Slug\$Slug.zip"
    if (-not (Test-Path $zip)) {
        Write-Info "$DisplayName not bundled (vendor\$Slug\$Slug.zip missing - dev tree?) - skipping auto-install"
        return $false
    }

    $verb = if (Test-Path $detect) { "Upgrading" } else { "Installing bundled" }
    Write-Info "$verb $DisplayName in the game folder..."
    Expand-Archive -Path $zip -DestinationPath $GameDir -Force
    if (-not (Test-Path $detect)) {
        Write-Fail "$DisplayName extraction did not produce $DetectRelPath - vendored zip may be corrupt"
        return $false
    }
    $now = Get-InstalledLoaderVersion -BinaryPath (Join-Path $GameDir $DetectRelPath)
    if ($now) { Write-Success "$DisplayName $now installed" } else { Write-Success "Installed bundled $DisplayName" }
    return $true
}

# Main execution
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  HeadTracking Mod Deployment Script" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

# Determine script location and source directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sourceDir = Split-Path -Parent $scriptDir

Write-Info "Source directory: $sourceDir"

# Validate mod source files exist
$missingFiles = @(Validate-ModFiles -SourceDir $sourceDir)
if ($missingFiles.Count -gt 0) {
    Write-Fail "Missing required mod files:"
    foreach ($file in $missingFiles) {
        Write-Host "  - $file" -ForegroundColor Red
    }
    exit 1
}
Write-Info "All mod files present"

# Find game installations
$gameDirs = @(Find-GameInstallations -CustomPath $GamePath)
if ($gameDirs.Count -eq 0) {
    Write-Fail "Cyberpunk 2077 installation not found!"
    Write-Host ""
    Write-Host "Detection order: CYBERPUNK_2077_PATH env var -> Steam appmanifest 1091500 ->" -ForegroundColor Yellow
    Write-Host "Steam folder 'Cyberpunk 2077' -> GOG registry -> Epic paths." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To specify a custom path, run:" -ForegroundColor Yellow
    Write-Host "  .\deploy.ps1 -GamePath ""D:\Your\Game\Path""" -ForegroundColor Cyan
    exit 1
}
Write-Info "Found $($gameDirs.Count) Cyberpunk 2077 installation(s):"
$gameDirs | ForEach-Object { Write-Host "  $_" -ForegroundColor Cyan }

# One copy. Returns a status string for the summary; a hard failure exits the
# script, since the remaining copies would fail the same way.
function Deploy-ToGame {
    param([string]$GameDir)

    Write-Host ""
    Write-Host "--- $GameDir" -ForegroundColor Cyan

    # Auto-install the bundled CET loader if the user doesn't already have one.
    Install-VendoredLoader -SourceDir $sourceDir -GameDir $GameDir -Slug 'cet' `
        -DetectRelPath 'bin\x64\plugins\cyber_engine_tweaks.asi' -DisplayName 'Cyber Engine Tweaks' | Out-Null

    # TweakXL applies the projectile restoration. Automatic fire cannot decouple
    # without it, so it is a hard requirement rather than an optional extra.
    Install-VendoredLoader -SourceDir $sourceDir -GameDir $GameDir -Slug 'tweakxl' `
        -DetectRelPath 'red4ext\plugins\TweakXL\TweakXL.dll' -DisplayName 'TweakXL' | Out-Null

    # Validate CET installation
    $cetDir = Validate-CETInstallation -GameDir $GameDir
    if (-not $cetDir) {
        Write-Fail "Cyber Engine Tweaks (CET) not found!"
        Write-Host ""
        Write-Host "CET is required for this mod to work. Installation steps:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  1. Download the latest release from:" -ForegroundColor White
        Write-Host "     https://github.com/maximegmd/CyberEngineTweaks/releases" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  2. Extract the zip contents to your game folder:" -ForegroundColor White
        Write-Host "     $GameDir" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  3. Verify installation - you should have:" -ForegroundColor White
        Write-Host "     $GameDir\bin\x64\plugins\cyber_engine_tweaks\" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  4. Launch the game and press ~ or Home to verify CET console opens" -ForegroundColor White
        Write-Host ""
        Write-Host "  5. Re-run this deploy script" -ForegroundColor White
        Write-Host ""
        Write-Host "Alternative: Install via Vortex from https://www.nexusmods.com/cyberpunk2077/mods/107" -ForegroundColor DarkGray
        exit 1
    }
    Write-Info "Found CET at: $cetDir"

    # Deploy CET mod
    $modDir = Join-Path $cetDir "mods\HeadTracking"
    Write-Info "Deploying CET mod to: $modDir"

    $result = Deploy-Mod -SourceDir $sourceDir -TargetDir $modDir
    if (-not $result) {
        Write-Fail "Deployment failed!"
        exit 1
    }

    # Auto-install the bundled RED4ext loader so the native aim plugin loads.
    Install-VendoredLoader -SourceDir $sourceDir -GameDir $GameDir -Slug 'red4ext' `
        -DetectRelPath 'red4ext\RED4ext.dll' -DisplayName 'RED4ext' | Out-Null

    # Deploy native RED4ext plugin (optional - for aim compensation)
    Write-Host ""
    Write-Info "Checking for native aim compensation plugin..."
    $nativeDeployed = Deploy-NativePlugin -SourceDir $sourceDir -GameDir $GameDir
    Deploy-Tweaks -SourceDir $sourceDir -GameDir $GameDir | Out-Null

    if ($nativeDeployed) { return "CET mod + native plugin + tweaks" }
    return "CET mod + tweaks (native plugin not built)"
}

$outcomes = @{}
foreach ($dir in $gameDirs) {
    $outcomes[$dir] = Deploy-ToGame -GameDir $dir
}

Write-Host ""
Write-Success "Mod deployed to $($gameDirs.Count) installation(s):"
foreach ($dir in $gameDirs) {
    Write-Host "  $dir" -ForegroundColor Green
    Write-Host "    $($outcomes[$dir])" -ForegroundColor DarkGray
}
Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  SETUP INSTRUCTIONS" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Configure OpenTrack:" -ForegroundColor White
Write-Host "   Output: UDP over network" -ForegroundColor Cyan
Write-Host "   IP: 127.0.0.1  Port: 4242  (the native plugin listens here)" -ForegroundColor Cyan
Write-Host ""
Write-Host "2. Launch Cyberpunk 2077" -ForegroundColor White
Write-Host "   The plugin opens UDP 4242 on load; no separate bridge process is needed." -ForegroundColor DarkGray
Write-Host ""
Write-Host "Restart the game to load the updated mod." -ForegroundColor DarkGray
Write-Host ""

exit 0
