#!/usr/bin/env pwsh
#Requires -Version 5.1
# ============================================================================
# cyberpunk-2077-headtracking/scripts/update-deps.ps1
# ============================================================================
# Bumps the vendored CET + RED4ext loaders under vendor/<slug>/ to the latest
# upstream release within the pinned version range, and writes refreshed
# LICENSE + README.md sidecars. The vendored copies are the install-time
# source of truth: both install.cmd (deploy.ps1) and the Lopari launcher
# extract them straight from vendor/ and never reach the network at install
# time.
#
# Usage:     pixi run update-deps
# Frequency: manual. Run when bumping CET/RED4ext for a new game patch, then
# commit the updated vendor/ tree. CI does not refresh.
# ============================================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

$scriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir

$moduleCandidates = @(
    (Join-Path $projectDir 'cameraunlock-core/powershell/ModLoaderSetup.psm1'),
    (Join-Path $projectDir '../cameraunlock-core/powershell/ModLoaderSetup.psm1')
)
$modulePath = $moduleCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $modulePath) {
    throw "ModLoaderSetup.psm1 not found. Run 'pixi run sync' to update the cameraunlock-core submodule."
}
Import-Module $modulePath -Force

# Cyber Engine Tweaks: the Lua/ASI loader. version.dll proxy + cyber_engine_tweaks.asi.
Update-VendoredLoader `
    -Name 'cet' `
    -OutputDir (Join-Path $projectDir 'vendor/cet') `
    -OutputFileName 'cet.zip' `
    -Owner 'maximegmd' -Repo 'CyberEngineTweaks' `
    -VersionPrefix 'v1.37.' `
    -AssetPattern '^cet_.*\.zip$' `
    -LicenseUrl 'https://raw.githubusercontent.com/maximegmd/CyberEngineTweaks/master/LICENSE' | Out-Null

# RED4ext: native RED4ext plugin loader. winmm.dll proxy + red4ext/RED4ext.dll.
# AssetPattern excludes the red4ext-symbols-*.zip debug asset.
Update-VendoredLoader `
    -Name 'red4ext' `
    -OutputDir (Join-Path $projectDir 'vendor/red4ext') `
    -OutputFileName 'red4ext.zip' `
    -Owner 'WopsS' -Repo 'RED4ext' `
    -VersionPrefix 'v1.' `
    -AssetPattern '^red4ext-\d.*\.zip$' `
    -LicenseName 'LICENSE.txt' | Out-Null

# TweakXL: applies tweaks/HeadTracking_ProjectileBullets.yaml, which is what makes
# rounds launch as projectiles so the aim can decouple from the view. Without it
# the mod loads but automatic fire stays glued to screen centre.
#
# Pinned to v1.11.3 rather than the 'v1.11.' prefix on purpose: v1.11.4 was
# published 2026-07-28 and was still inside our two-week minimum age for a new
# dependency release when this was added. Move to 'v1.11.' once that has aged.
Update-VendoredLoader `
    -Name 'tweakxl' `
    -OutputDir (Join-Path $projectDir 'vendor/tweakxl') `
    -OutputFileName 'tweakxl.zip' `
    -Owner 'psiberx' -Repo 'cp2077-tweak-xl' `
    -VersionPrefix 'v1.11.3' `
    -AssetPattern '^TweakXL-.*\.zip$' | Out-Null

Write-Host ""
Write-Host "Vendored CET + RED4ext + TweakXL refreshed. Review and commit the changes under vendor/." -ForegroundColor Green
