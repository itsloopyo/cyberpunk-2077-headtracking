[CmdletBinding()]
param([switch]$AllowDirty)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot '..')

Import-Module (Join-Path $ProjectRoot 'cameraunlock-core/powershell/NightlyRelease.psm1') -Force

$installCmd = Join-Path $ProjectRoot 'scripts/install.cmd'
$match = Select-String -Path $installCmd -Pattern 'set "MOD_VERSION=([^"]+)"' | Select-Object -First 1
if (-not $match) {
    throw "Could not extract MOD_VERSION from $installCmd"
}
$version = $match.Matches[0].Groups[1].Value

Publish-NightlyBuild `
    -ModId 'cyberpunk-2077' `
    -ModName 'HeadTracking' `
    -Version $version `
    -ProjectRoot $ProjectRoot `
    -BuildCommand 'pixi run build' `
    -AllowDirty:$AllowDirty
