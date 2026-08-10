<#
.SYNOPSIS
    Cut a versioned release of the HeadTracking mod, fully unattended.

.DESCRIPTION
    Runs end-to-end with zero prompts. The user typing
    `pixi run release <bump|version>` is the authorization; there is no
    second gate.

    Workflow:
      1. Resolve target version (keyword bump or literal X.Y.Z[-prerelease]).
      2. Verify on `main`, working tree clean, target tag absent.
      3. Update version in canonical sources (install.cmd MOD_VERSION,
         modules/GameUI.lua version field).
      4. pixi run build (release config).
      5. Generate CHANGELOG.md from commits since the last tag.
      6. Commit "Release v<version>" with version bump + changelog.
      7. Create annotated tag v<version>.
      8. Push commits + tag (triggers .github/workflows/release.yml).

.PARAMETER Version
    Required. Either 'major' / 'minor' / 'patch' (bump from latest tag),
    a literal semantic version (e.g. '1.0.0', '2.0.0-beta.1'), or
    'nightly' to refresh the rolling `dev` GitHub pre-release.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Version,
    # Ship a release even when there are no user-facing commits since the
    # last tag (writes a maintenance changelog entry instead of aborting).
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info    { param([string]$m) Write-Host "[INFO] $m"    -ForegroundColor Cyan }
function Write-Success { param([string]$m) Write-Host "[SUCCESS] $m" -ForegroundColor Green }
function Write-Fail    { param([string]$m) Write-Host "[ERROR] $m"   -ForegroundColor Red; exit 1 }

$scriptDir   = Split-Path -Parent $PSCommandPath
$projectRoot = Split-Path -Parent $scriptDir
Set-Location $projectRoot

if (-not $Version) {
    Write-Error 'Usage: pixi run release <major|minor|patch|nightly|X.Y.Z>'
    exit 1
}

if ($Version -eq 'nightly') {
    & (Join-Path $scriptDir 'release-nightly.ps1')
    exit $LASTEXITCODE
}

Import-Module (Join-Path $projectRoot 'cameraunlock-core/powershell/ReleaseWorkflow.psm1') -Force

# Mirrors New-ChangelogFromCommits' insertion so a -Force maintenance entry
# lands in the same place with the same shape.
function Add-MaintenanceChangelogEntry {
    param([string]$Path, [string]$NewVersion)
    $date = Get-Date -Format 'yyyy-MM-dd'
    $entry = "## [$NewVersion] - $date`n`n### Changed`n`n- Maintenance release (no user-facing changes).`n`n"
    $changelog = Get-Content $Path -Raw
    if ($changelog -match '(?s)(# Changelog.*?)(## \[)') {
        $changelog = $changelog -replace '(?s)(# Changelog.*?\n\n)', "`$1$entry"
    } else {
        $changelog = $changelog -replace '(?s)(# Changelog.*?\n)', "`$1$entry"
    }
    $changelog = $changelog.TrimEnd() + "`n"
    Set-Content $Path $changelog -NoNewline
}

Write-Host ''
Write-Host '========================================' -ForegroundColor Yellow
Write-Host '  HeadTracking Release' -ForegroundColor Yellow
Write-Host '========================================' -ForegroundColor Yellow
Write-Host ''

# ---- Step 1: Resolve version ----------------------------------------------
Write-Info 'Step 1/8: Resolving release version...'
$latestTag = git tag -l 'v*' --sort=-v:refname 2>$null | Select-Object -First 1
$currentVersion = if ($latestTag) { $latestTag -replace '^v','' } else { '0.0.0' }
try {
    $Version = Resolve-ReleaseVersion -Argument $Version -CurrentVersion $currentVersion
} catch {
    Write-Fail $_.Exception.Message
}
$tagName = "v$Version"
Write-Host "  [OK] $currentVersion -> $Version" -ForegroundColor Green

# ---- Step 2: Verify preconditions -----------------------------------------
Write-Info 'Step 2/8: Verifying preconditions (branch, tree, tag)...'
$currentBranch = (& git rev-parse --abbrev-ref HEAD).Trim()
if ($currentBranch -ne 'main') {
    Write-Fail "Releases must be cut from 'main' (currently on '$currentBranch')."
}
if (-not (Test-CleanGitStatus)) {
    git status --short
    Write-Fail 'Working tree is not clean. Commit or stash first.'
}
if (Test-GitTagExists -Tag $tagName) {
    Write-Fail "Tag $tagName already exists."
}
Write-Host "  [OK] On main, tree clean, tag $tagName free" -ForegroundColor Green

# ---- Step 3: Generate CHANGELOG.md ----------------------------------------
# This is the gate that aborts when there are no user-facing commits, so run
# it BEFORE mutating any version files or building - a failure here then
# leaves a clean tree instead of stranding a half-applied version bump with
# no tag.
Write-Info 'Step 3/8: Generating CHANGELOG.md from commits...'
$changelogPath = Join-Path $projectRoot 'CHANGELOG.md'
$hasExistingTags = git tag -l 2>$null
if (-not $hasExistingTags) {
    # First release - ensure a baseline CHANGELOG exists
    if (-not (Test-Path $changelogPath)) {
        $date = Get-Date -Format 'yyyy-MM-dd'
        "# Changelog`n`n## [$Version] - $date`n`nFirst release.`n" | Set-Content $changelogPath
        Write-Host "  [OK] Wrote initial CHANGELOG.md" -ForegroundColor Green
    }
} else {
    try {
        $result = New-ChangelogFromCommits -ChangelogPath $changelogPath -Version $Version
        if ($result.AlreadyExists) {
            Write-Host "  [OK] Changelog already has [$Version] (kept)" -ForegroundColor Green
        } else {
            Write-Host ("  [OK] Changelog updated: {0} feat / {1} fix / {2} change" -f $result.Features, $result.Fixes, $result.Changes) -ForegroundColor Green
        }
    } catch {
        if (-not $Force) {
            Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'No user-facing changes to release. Re-run with -Force for a maintenance release.' -ForegroundColor Yellow
            exit 1
        }
        Write-Host 'No user-facing commits since last tag - writing maintenance entry (-Force).' -ForegroundColor Yellow
        Add-MaintenanceChangelogEntry -Path $changelogPath -NewVersion $Version
    }
}

# ---- Step 4: Update version in canonical sources --------------------------
Write-Info 'Step 4/8: Updating version in canonical sources...'

$installCmd  = Join-Path $projectRoot 'scripts/install.cmd'
$gameUiLua   = Join-Path $projectRoot 'modules/GameUI.lua'

if (-not (Test-Path $installCmd)) { Write-Fail "Missing canonical version source: $installCmd" }

$installRaw = [System.IO.File]::ReadAllText($installCmd)
if ($installRaw -notmatch 'set "MOD_VERSION=[^"]+"') {
    Write-Fail "MOD_VERSION line not found in $installCmd"
}
$installRaw = [regex]::Replace($installRaw, 'set "MOD_VERSION=[^"]+"', "set `"MOD_VERSION=$Version`"")
[System.IO.File]::WriteAllText($installCmd, $installRaw)
Write-Host "  [OK] scripts/install.cmd MOD_VERSION = $Version" -ForegroundColor Green

if (Test-Path $gameUiLua) {
    $luaRaw = [System.IO.File]::ReadAllText($gameUiLua)
    if ($luaRaw -match 'version\s*=\s*"[^"]+"') {
        $luaRaw = [regex]::Replace($luaRaw, '(version\s*=\s*")[^"]+(")', "`${1}$Version`${2}", 1)
        [System.IO.File]::WriteAllText($gameUiLua, $luaRaw)
        Write-Host "  [OK] modules/GameUI.lua version = $Version" -ForegroundColor Green
    }
}

# ---- Step 5: Build (release config) ---------------------------------------
Write-Info 'Step 5/8: pixi run build...'
& pixi run build
if ($LASTEXITCODE -ne 0) { Write-Fail "pixi run build failed (exit $LASTEXITCODE)" }
Write-Host '  [OK] Build succeeded' -ForegroundColor Green

# ---- Step 6: Commit -------------------------------------------------------
Write-Info 'Step 6/8: Committing version bump + changelog...'
$relInstall = 'scripts/install.cmd'
$relGameUi  = 'modules/GameUI.lua'
$relChangelog = 'CHANGELOG.md'

& git add -- $relInstall $relGameUi $relChangelog | Out-Null
$staged = & git diff --cached --name-only
if (-not $staged) {
    Write-Fail 'No changes staged - version files were unchanged. Aborting.'
}
& git commit -m "Release v$Version"
if ($LASTEXITCODE -ne 0) { Write-Fail 'git commit failed' }
Write-Host '  [OK] Release commit created' -ForegroundColor Green

# ---- Step 7: Annotated tag ------------------------------------------------
Write-Info "Step 7/8: Creating annotated tag $tagName..."
$tagBody = @"
Release $tagName

HeadTracking mod version $Version for Cyberpunk 2077.
See CHANGELOG.md for release notes.
"@
& git tag -a $tagName -m $tagBody
if ($LASTEXITCODE -ne 0) { Write-Fail 'git tag failed' }
Write-Host "  [OK] Tag $tagName created" -ForegroundColor Green

# ---- Step 8: Push commits + tag -------------------------------------------
Write-Info 'Step 8/8: Pushing commit + tag to origin...'
& git push origin main
if ($LASTEXITCODE -ne 0) { Write-Fail 'git push of main failed' }
& git push origin $tagName
if ($LASTEXITCODE -ne 0) { Write-Fail "git push of $tagName failed" }
Write-Host '  [OK] Pushed' -ForegroundColor Green

Write-Host ''
Write-Host '========================================' -ForegroundColor Yellow
Write-Success "Release $tagName cut."
Write-Host ''
Write-Host '  GitHub Actions (.github/workflows/release.yml) will now build and publish the GitHub Release.' -ForegroundColor DarkGray
Write-Host ''

exit 0
