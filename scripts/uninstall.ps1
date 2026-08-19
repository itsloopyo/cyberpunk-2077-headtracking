<#
.SYNOPSIS
    Remove HeadTracking mod from Cyberpunk 2077 CET mods directory.

.DESCRIPTION
    Deletes the HeadTracking CET mod folder and the native RED4ext plugin DLL,
    if present. Leaves user config.json alone only when -KeepConfig is set.

.PARAMETER GamePath
    Optional custom path to Cyberpunk 2077 installation.

.PARAMETER KeepConfig
    If set, preserves the user's config.json under the CET mod folder
    (the mod folder itself is still removed, but config is backed up
    to %TEMP%\HeadTracking-config-backup.json).

.PARAMETER Force
    Accepted for compatibility with the CameraUnlock uninstall contract
    (/force escalates loader removal in BepInEx/MelonLoader/etc. mods).
    This mod ships only a CET Lua mod and a RED4ext plugin DLL - the
    frameworks themselves are user-managed - so -Force is a no-op here.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GamePath,

    [Parameter(Mandatory = $false)]
    [switch]$KeepConfig,

    [Parameter(Mandatory = $false)]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Detection delegates to GamePathDetection.psm1 when the cameraunlock-core
# submodule is on disk (dev tree). Release ZIPs and Lopari profiles ship
# without the submodule and rely on the caller to pass -GamePath explicitly
# (uninstall.cmd resolves the path via shared/find-game.ps1 first, then
# forwards). Skip the import gracefully when the module isn't present so the
# script doesn't die before it can even look at $GamePath.
$projectRootForUninstall = Split-Path -Parent $PSScriptRoot
$gamePathDetectionModule = Join-Path $projectRootForUninstall 'cameraunlock-core/powershell/GamePathDetection.psm1'
$haveGamePathDetection = $false
if (Test-Path -LiteralPath $gamePathDetectionModule) {
    Import-Module $gamePathDetectionModule -Force
    $haveGamePathDetection = $true
}

function Find-GameInstallation {
    param([string]$CustomPath)

    if ($CustomPath) {
        $exePath = Join-Path $CustomPath 'bin\x64\Cyberpunk2077.exe'
        if ((Test-Path $CustomPath) -and (Test-Path $exePath)) { return $CustomPath }
        Write-Fail "Provided -GamePath does not contain Cyberpunk 2077: $CustomPath"
        exit 1
    }

    if (-not $haveGamePathDetection) {
        Write-Fail "Pass -GamePath explicitly: this build doesn't include the auto-detection module."
        exit 1
    }

    $found = Find-GamePath -GameId 'cyberpunk-2077'
    if ($found) { return $found }
    return $null
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  HeadTracking Mod Uninstall Script" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

$gameDir = Find-GameInstallation -CustomPath $GamePath
if (-not $gameDir) {
    Write-Fail "Cyberpunk 2077 installation not found!"
    Write-Host "Specify a path: .\uninstall.ps1 -GamePath ""D:\Your\Game\Path""" -ForegroundColor Yellow
    exit 1
}
Write-Info "Found Cyberpunk 2077 at: $gameDir"

$modDir = Join-Path $gameDir "bin\x64\plugins\cyber_engine_tweaks\mods\HeadTracking"
$dllPath = Join-Path $gameDir "red4ext\plugins\HeadTrackingAim.dll"

$removedSomething = $false

if (Test-Path $modDir) {
    if ($KeepConfig) {
        $cfgSrc = Join-Path $modDir "config.json"
        if (Test-Path $cfgSrc) {
            $backup = Join-Path $env:TEMP "HeadTracking-config-backup.json"
            Copy-Item -Path $cfgSrc -Destination $backup -Force
            Write-Info "Backed up config.json to: $backup"
        }
    }
    Remove-Item -Path $modDir -Recurse -Force
    Write-Info "Removed CET mod folder: $modDir"
    $removedSomething = $true
} else {
    Write-Info "CET mod folder not present (already removed?)"
}

if (Test-Path $dllPath) {
    Remove-Item -Path $dllPath -Force
    Write-Info "Removed native plugin: $dllPath"
    $removedSomething = $true
} else {
    Write-Info "Native plugin not present (already removed or never installed)"
}

# Take our hotkeys back out of CET's shared bindings.json. Leaving a
# HeadTracking section behind keeps four keys claimed in CET's binding UI for a
# mod that is no longer installed, and the next mod to want Home or End sees
# them as taken.
function Remove-CetBindings {
    param([string]$GameDir)

    $bindingsPath = Join-Path $GameDir "bin\x64\plugins\cyber_engine_tweaks\bindings.json"
    if (-not (Test-Path -LiteralPath $bindingsPath)) { return }

    # PSCustomObject rather than -AsHashtable: the latter is PowerShell 7+ and
    # throws on the 5.1 that ships with Windows.
    try {
        $raw = Get-Content -LiteralPath $bindingsPath -Raw -Encoding UTF8
        if (-not $raw -or $raw.Trim().Length -eq 0) { return }
        $doc = $raw | ConvertFrom-Json
    } catch {
        Write-Info "bindings.json is unreadable ($($_.Exception.Message)) - leaving it alone"
        return
    }

    if (-not ($doc.PSObject.Properties.Name -contains 'HeadTracking')) { return }

    $kept = [ordered]@{}
    foreach ($prop in $doc.PSObject.Properties) {
        if ($prop.Name -eq 'HeadTracking') { continue }
        $kept[$prop.Name] = $prop.Value
    }

    $json = if ($kept.Count -gt 0) { $kept | ConvertTo-Json -Depth 10 } else { "{}" }
    Set-Content -LiteralPath $bindingsPath -Value $json -Encoding UTF8
    Write-Info "Removed the HeadTracking section from bindings.json ($($kept.Count) other section(s) preserved)"

    # The .bak is the snapshot deploy.ps1 takes before merging. It exists to
    # recover from a bad merge during install; once our section is gone it is
    # just a stale copy of a file we no longer appear in.
    $backupPath = "$bindingsPath.bak"
    if (Test-Path -LiteralPath $backupPath) {
        Remove-Item -LiteralPath $backupPath -Force
        Write-Info "Removed bindings.json.bak"
    }
}

Remove-CetBindings -GameDir $gameDir

Write-Host ""
if ($removedSomething) {
    Write-Success "HeadTracking uninstalled successfully."
} else {
    Write-Info "Nothing to uninstall - mod was not installed."
}
exit 0
