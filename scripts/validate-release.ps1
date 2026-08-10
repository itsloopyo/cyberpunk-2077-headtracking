<#
.SYNOPSIS
    Pre-release validation for HeadTracking mod.

.DESCRIPTION
    Validates all required files are present, checks for changelog entries,
    verifies mod structure, and performs additional release-readiness checks.
    This script is run before creating a release package.

.PARAMETER Version
    Optional version to validate changelog entry for.
    If not provided, uses the latest git tag.

.EXAMPLE
    .\validate-release.ps1
    .\validate-release.ps1 -Version "1.0.0"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Color output helpers
function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

# Determine script directory and project root
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectRoot = Split-Path -Parent $scriptDir

Set-Location $projectRoot

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  HeadTracking Release Validation" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""

Write-Info "Project root: $projectRoot"

$errors = 0
$warnings = 0

# Required files for a complete release
$requiredFiles = @(
    "init.lua",
    "modules/udp.lua",
    "modules/camera.lua",
    "modules/settings.lua",
    "modules/state.lua",
    "modules/ui.lua",
    "modules/GameUI.lua",
    "README.md",
    "CHANGELOG.md",
    "LICENSE",
    "THIRD-PARTY-NOTICES.md"
)

# Optional but recommended files
$recommendedFiles = @(
    "modules/nativesettings.lua",
    "config.json"
)

Write-Host ""
Write-Info "Checking required files..."

foreach ($file in $requiredFiles) {
    $fullPath = Join-Path $projectRoot $file
    if (Test-Path $fullPath) {
        Write-Host "  [OK] $file" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] $file" -ForegroundColor Red
        $errors++
    }
}

Write-Host ""
Write-Info "Checking recommended files..."

foreach ($file in $recommendedFiles) {
    $fullPath = Join-Path $projectRoot $file
    if (Test-Path $fullPath) {
        Write-Host "  [OK] $file" -ForegroundColor Green
    }
    else {
        Write-Host "  [SKIP] $file (optional)" -ForegroundColor Yellow
        $warnings++
    }
}

Write-Host ""
Write-Info "Checking modules directory..."

$modulesDir = Join-Path $projectRoot "modules"
if (Test-Path $modulesDir) {
    $luaFiles = Get-ChildItem -Path $modulesDir -Filter "*.lua"
    Write-Host "  [OK] modules/ directory exists ($($luaFiles.Count) Lua files)" -ForegroundColor Green
}
else {
    Write-Host "  [MISSING] modules/ directory" -ForegroundColor Red
    $errors++
}

Write-Host ""
Write-Info "Checking version and changelog..."

# Determine version to check
$versionToCheck = $Version
if (-not $versionToCheck) {
    # Try to get latest git tag
    try {
        $latestTag = git describe --tags --abbrev=0 2>$null
        if ($latestTag) {
            $versionToCheck = $latestTag.TrimStart('v')
            Write-Info "Using version from git tag: $versionToCheck"
        }
    }
    catch {
        Write-Warn "No git tag found, skipping version validation"
    }
}

if ($versionToCheck) {
    $changelogPath = Join-Path $projectRoot "CHANGELOG.md"
    if (Test-Path $changelogPath) {
        $changelogContent = Get-Content $changelogPath -Raw
        if ($changelogContent -match "\[$versionToCheck\]") {
            Write-Host "  [OK] Changelog entry found for version $versionToCheck" -ForegroundColor Green
        }
        else {
            Write-Host "  [MISSING] No changelog entry for version $versionToCheck" -ForegroundColor Red
            Write-Host "       Add entry: ## [$versionToCheck] - $(Get-Date -Format 'yyyy-MM-dd')" -ForegroundColor Yellow
            $errors++
        }
    }
}
else {
    Write-Host "  [SKIP] Version validation (no version specified or tag found)" -ForegroundColor Yellow
}

Write-Host ""
Write-Info "Checking init.lua structure..."

$initPath = Join-Path $projectRoot "init.lua"
if (Test-Path $initPath) {
    $initContent = Get-Content $initPath -Raw

    # Check for required CET event registrations
    if ($initContent -match "registerForEvent.*onInit") {
        Write-Host "  [OK] registerForEvent('onInit') present" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] registerForEvent('onInit')" -ForegroundColor Red
        $errors++
    }

    if ($initContent -match "registerForEvent.*onUpdate") {
        Write-Host "  [OK] registerForEvent('onUpdate') present" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] registerForEvent('onUpdate')" -ForegroundColor Red
        $errors++
    }

    if ($initContent -match "registerHotkey") {
        $hotkeyMatches = [regex]::Matches($initContent, "registerHotkey")
        Write-Host "  [OK] registerHotkey calls found ($($hotkeyMatches.Count))" -ForegroundColor Green
    }
    else {
        Write-Host "  [MISSING] No registerHotkey calls" -ForegroundColor Red
        $errors++
    }
}

Write-Host ""
Write-Info "Checking module export patterns..."

$moduleFiles = @(
    "udp.lua",
    "camera.lua",
    "settings.lua",
    "state.lua",
    "ui.lua"
)

foreach ($moduleFile in $moduleFiles) {
    $modulePath = Join-Path $projectRoot "modules\$moduleFile"
    if (Test-Path $modulePath) {
        $moduleContent = Get-Content $modulePath -Raw
        if ($moduleContent -match "^return\s+\w+") {
            Write-Host "  [OK] $moduleFile exports module" -ForegroundColor Green
        }
        elseif ($moduleContent -match "return\s+\w+") {
            Write-Host "  [OK] $moduleFile exports module" -ForegroundColor Green
        }
        else {
            Write-Host "  [WARN] $moduleFile may not export properly" -ForegroundColor Yellow
            $warnings++
        }
    }
}

Write-Host ""
Write-Info "Checking for release issues..."

# Check for debug/development code
$allLuaFiles = @("init.lua") + (Get-ChildItem -Path (Join-Path $projectRoot "modules") -Filter "*.lua" | ForEach-Object { "modules\$($_.Name)" })

$debugPatterns = @(
    "print.*DEBUG",
    "print.*TODO",
    "--.*TODO",
    "--.*FIXME",
    "--.*HACK",
    "--.*XXX"
)

$foundDebug = $false
foreach ($file in $allLuaFiles) {
    $filePath = Join-Path $projectRoot $file
    if (Test-Path $filePath) {
        $content = Get-Content $filePath -Raw
        foreach ($pattern in $debugPatterns) {
            if ($content -match $pattern) {
                if (-not $foundDebug) {
                    Write-Warn "Found debug/TODO comments:"
                    $foundDebug = $true
                }
                Write-Host "       $file" -ForegroundColor Yellow
                $warnings++
                break
            }
        }
    }
}

if (-not $foundDebug) {
    Write-Host "  [OK] No debug/TODO comments found" -ForegroundColor Green
}

# Check for hardcoded paths
$foundHardcoded = $false
foreach ($file in $allLuaFiles) {
    $filePath = Join-Path $projectRoot $file
    if (Test-Path $filePath) {
        $content = Get-Content $filePath
        foreach ($line in $content) {
            if ($line -match '[CD]:\\|/home/|/Users/') {
                if (-not $foundHardcoded) {
                    Write-Warn "Found hardcoded paths:"
                    $foundHardcoded = $true
                }
                Write-Host "       $file" -ForegroundColor Yellow
                $warnings++
                break
            }
        }
    }
}

if (-not $foundHardcoded) {
    Write-Host "  [OK] No hardcoded paths found" -ForegroundColor Green
}

Write-Host ""
Write-Info "Checking README.md content..."

$readmePath = Join-Path $projectRoot "README.md"
if (Test-Path $readmePath) {
    $readmeContent = Get-Content $readmePath -Raw

    $readmeChecks = @(
        @{ Pattern = "(?i)install"; Name = "Installation instructions" },
        @{ Pattern = "(?i)opentrack|udp|4242"; Name = "OpenTrack configuration" },
        @{ Pattern = "(?i)hotkey|F8|F9|toggle|recenter"; Name = "Hotkey documentation" },
        @{ Pattern = "(?i)requirement|cet|cyber.engine.tweaks"; Name = "Requirements section" }
    )

    foreach ($check in $readmeChecks) {
        if ($readmeContent -match $check.Pattern) {
            Write-Host "  [OK] $($check.Name)" -ForegroundColor Green
        }
        else {
            Write-Host "  [WARN] $($check.Name) may be missing" -ForegroundColor Yellow
            $warnings++
        }
    }
}

Write-Host ""
Write-Host "========================================"

if ($errors -gt 0) {
    Write-Fail "Validation FAILED with $errors error(s) and $warnings warning(s)"
    Write-Host ""
    exit 1
}
elseif ($warnings -gt 0) {
    Write-Warn "Validation PASSED with $warnings warning(s)"
    Write-Host ""
    Write-Host "Consider addressing warnings before release." -ForegroundColor Yellow
    exit 0
}
else {
    Write-Success "Validation PASSED!"
    Write-Host ""
    Write-Host "Ready for release." -ForegroundColor Green
    exit 0
}
