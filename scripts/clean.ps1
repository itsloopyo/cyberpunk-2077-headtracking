$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
Set-Location $projectRoot

foreach ($path in 'dist', 'release', 'native/build', 'native/out') {
    if (Test-Path $path) {
        Remove-Item $path -Recurse -Force
    }
}

Write-Host 'Build artifacts cleaned' -ForegroundColor Green
