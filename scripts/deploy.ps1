<#
.SYNOPSIS
    Deploy HeadTracking mod to Cyberpunk 2077 CET mods directory.

.DESCRIPTION
    Validates game and CET installation, then copies mod files to the correct location.
    Supports multiple common game installation paths.

.PARAMETER GamePath
    Optional custom path to Cyberpunk 2077 installation.
    If not provided, searches common installation locations.

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

function Find-GameInstallation {
    param(
        [string]$CustomPath
    )

    if ($CustomPath) {
        $exePath = Join-Path $CustomPath 'bin\x64\Cyberpunk2077.exe'
        if ((Test-Path $CustomPath) -and (Test-Path $exePath)) { return $CustomPath }
        Write-Fail "Provided -GamePath does not contain Cyberpunk 2077: $CustomPath"
        exit 1
    }

    $found = Find-GamePath -GameId 'cyberpunk-2077'
    if ($found) { return $found }
    return $null
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

    # Copy config.json if it exists and target doesn't have one
    $configSource = Join-Path $SourceDir "config.json"
    $configTarget = Join-Path $TargetDir "config.json"
    if ((Test-Path $configSource) -and (-not (Test-Path $configTarget))) {
        Copy-Item -Path $configSource -Destination $configTarget -Force
        Write-Info "Copied default config.json"
    }
    elseif (Test-Path $configTarget) {
        Write-Info "Preserved existing config.json"
    }

    return $true
}

function Merge-CetBindings {
    param(
        [string]$CetDir
    )

    # CET encodes hotkey bindings as (Windows VK code << 48). One binding per action.
    # For each action we have a preferred VK and a fallback chain;
    # if the preferred key is already bound *anywhere else in the file* (any
    # other mod or our own migrated entry), we pick the first free fallback.
    # Existing HeadTracking bindings that the user deliberately set are never
    # touched.

    function VkValue([int]$vk) {
        # 0x<vk>000000000000 - PowerShell int64 shift left by 48.
        return [int64]$vk * [int64]281474976710656
    }

    # `ConvertFrom-Json -AsHashtable` is PowerShell 7+. On Windows PowerShell 5.1
    # (default on Windows through at least 11 24H2) the flag doesn't exist and
    # the cmdlet throws "parameter cannot be found". That error was previously
    # being swallowed by the try/catch and the merge was silently skipped - no
    # bindings ever got written. Instead, parse to PSCustomObject (universal)
    # and shim it into an OrderedDictionary so the rest of this function's
    # hashtable-style indexing works unchanged.
    function ConvertTo-OrderedDict {
        param($InputObject)
        if ($null -eq $InputObject) { return $null }
        if ($InputObject -is [System.Collections.IDictionary]) {
            $out = [ordered]@{}
            foreach ($k in $InputObject.Keys) {
                $out[$k] = ConvertTo-OrderedDict -InputObject $InputObject[$k]
            }
            return $out
        }
        if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
            $out = [ordered]@{}
            foreach ($prop in $InputObject.PSObject.Properties) {
                $out[$prop.Name] = ConvertTo-OrderedDict -InputObject $prop.Value
            }
            return $out
        }
        if ($InputObject -is [Array] -or $InputObject -is [System.Collections.IList]) {
            return @($InputObject | ForEach-Object { ConvertTo-OrderedDict -InputObject $_ })
        }
        return $InputObject
    }

    $choices = [ordered]@{
        ToggleHeadTracking     = @(
            @{ vk = 0x23; name = "End"      },
            @{ vk = 0x61; name = "Numpad1"  },
            @{ vk = 0x7D; name = "F14"      }
        )
        TogglePositionTracking = @(
            @{ vk = 0x21; name = "PageUp"   },
            @{ vk = 0x69; name = "Numpad9"  },
            @{ vk = 0x7E; name = "F15"      }
        )
        ToggleYawMode          = @(
            @{ vk = 0x22; name = "PageDown" },
            @{ vk = 0x63; name = "Numpad3"  },
            @{ vk = 0x7F; name = "F16"      }
        )
    }

    # Legacy defaults that earlier versions of the mod shipped. If we see them,
    # they're stale - replace with the preferred pick. Anything else is treated
    # as a deliberate customization and left alone.
    $legacy = @{
        ToggleHeadTracking   = [int64]53480245575024640   # VK_OEM_PERIOD
    }

    $bindingsPath = Join-Path $CetDir "bindings.json"
    $backupPath   = "$bindingsPath.bak"

    # Safety net: snapshot the current file before we touch it. If the merge
    # ever corrupts something, the user can copy .bak back. We overwrite the
    # single .bak each install so it always reflects the pre-deploy state.
    if (Test-Path $bindingsPath) {
        try {
            Copy-Item -Path $bindingsPath -Destination $backupPath -Force
            Write-Info "Saved bindings.json backup to: $backupPath"
        } catch {
            Write-Info "Could not back up bindings.json ($($_.Exception.Message)) - continuing cautiously"
        }
    }

    $doc = [ordered]@{}
    if (Test-Path $bindingsPath) {
        try {
            $raw = Get-Content -Path $bindingsPath -Raw -Encoding UTF8
            if ($raw -and $raw.Trim().Length -gt 0) {
                $parsed = ConvertTo-OrderedDict -InputObject ($raw | ConvertFrom-Json)
                if ($parsed -is [System.Collections.Specialized.OrderedDictionary]) { $doc = $parsed }
            }
        } catch {
            Write-Info "Existing bindings.json was unreadable ($($_.Exception.Message))"
            Write-Info "Refusing to overwrite a file we can't parse - skipping bindings merge."
            return
        }
    }

    if (-not $doc.Contains("HeadTracking") -or $null -eq $doc["HeadTracking"]) {
        $doc["HeadTracking"] = [ordered]@{}
    }
    $ht = $doc["HeadTracking"]
    if ($ht.Contains("ToggleReticle")) {
        $ht.Remove("ToggleReticle")
    }

    # Collect VK values already claimed by anything in the file, INCLUDING our
    # own section (for the actions we're going to keep). We'll add to this as
    # we decide new bindings so two of our actions don't collide either.
    $used = @{}
    function Add-Used([hashtable]$used, [int64]$v, [string]$label) {
        if ($v -gt 0) { $used[$v] = $label }
    }

    foreach ($sec in $doc.Keys) {
        $section = $doc[$sec]
        if ($section -isnot [hashtable] -and $section -isnot [System.Collections.Specialized.OrderedDictionary]) { continue }
        foreach ($k in @($section.Keys)) {
            $v = $section[$k]
            if ($v -is [int] -or $v -is [long] -or $v -is [int64]) {
                Add-Used $used ([int64]$v) "$sec.$k"
            }
        }
    }

    $report = @()
    foreach ($action in $choices.Keys) {
        $currentVal = $null
        if ($ht.Contains($action)) { $currentVal = [int64]$ht[$action] }

        # Keep existing user customization? Yes, unless it's 0 or a known legacy default.
        $isLegacy = $legacy.ContainsKey($action) -and $currentVal -eq $legacy[$action]
        $keepExisting = ($null -ne $currentVal) -and ($currentVal -ne 0) -and (-not $isLegacy)

        if ($keepExisting) {
            $report += [pscustomobject]@{
                Action = $action
                Key    = "kept existing (VK 0x{0:X2})" -f (($currentVal -shr 48) -band 0xFF)
                Status = "kept"
            }
            continue
        }

        # For this action we'll pick from the choices list. When we drop a
        # legacy value, its VK is no longer "used" (we're replacing it).
        if ($isLegacy) {
            $used.Remove([int64]$currentVal) | Out-Null
        }

        $picked = $null
        foreach ($opt in $choices[$action]) {
            $vkVal = VkValue $opt.vk
            if (-not $used.ContainsKey($vkVal)) {
                $picked = $opt
                $ht[$action] = $vkVal
                Add-Used $used $vkVal "HeadTracking.$action"
                break
            }
        }

        if ($null -eq $picked) {
            # Every choice taken - leave unbound (0) rather than clobber.
            $ht[$action] = [int64]0
            $report += [pscustomobject]@{
                Action = $action
                Key    = "(all preferred keys taken; left unbound)"
                Status = "skipped"
            }
        } else {
            $note = if ($picked -eq $choices[$action][0]) { "preferred" } else { "fallback - preferred taken" }
            $report += [pscustomobject]@{
                Action = $action
                Key    = "$($picked.name) ($note)"
                Status = "set"
            }
        }
    }

    # Log everything we're PRESERVING (i.e., not HeadTracking's managed actions)
    # so the user can see nothing else has been touched. Catches any regression
    # in the merge logic quickly.
    $preserved = @()
    foreach ($sec in $doc.Keys) {
        $section = $doc[$sec]
        if ($section -isnot [hashtable] -and $section -isnot [System.Collections.Specialized.OrderedDictionary]) { continue }
        foreach ($k in @($section.Keys)) {
            if ($sec -eq "HeadTracking" -and $choices.Contains($k)) { continue }
            $preserved += "${sec}.${k} = $($section[$k])"
        }
    }

    $json = $doc | ConvertTo-Json -Depth 10
    Set-Content -Path $bindingsPath -Value $json -Encoding UTF8

    # Post-write sanity check: re-read and verify the preserved keys still
    # exist and have the same value. ConvertTo-Json in Windows PowerShell 5.1
    # can mangle very large integers; if that happens we restore from .bak.
    $corruptionDetected = $false
    if (Test-Path $bindingsPath) {
        try {
            $reread = ConvertTo-OrderedDict -InputObject ((Get-Content -Path $bindingsPath -Raw -Encoding UTF8) | ConvertFrom-Json)
            foreach ($line in $preserved) {
                $parts = $line -split " = ", 2
                $path  = $parts[0]
                $expected = [int64]$parts[1]
                $secName, $keyName = $path -split "\.", 2
                $actual = $null
                if ($reread.Contains($secName) -and $reread[$secName].Contains($keyName)) {
                    $actual = [int64]$reread[$secName][$keyName]
                }
                if ($actual -ne $expected) {
                    Write-Host "[ERROR] bindings.json roundtrip corrupted key $path (was $expected, now $actual)" -ForegroundColor Red
                    $corruptionDetected = $true
                }
            }
        } catch {
            Write-Host "[ERROR] Could not verify bindings.json after write: $($_.Exception.Message)" -ForegroundColor Red
            $corruptionDetected = $true
        }
    }

    if ($corruptionDetected -and (Test-Path $backupPath)) {
        Write-Host "[INFO] Restoring bindings.json from backup due to detected corruption" -ForegroundColor Yellow
        Copy-Item -Path $backupPath -Destination $bindingsPath -Force
        return
    }

    Write-Host ""
    Write-Host "HeadTracking hotkey bindings:" -ForegroundColor Yellow
    foreach ($row in $report) {
        $color = switch ($row.Status) { "set" {"Green"} "kept" {"Cyan"} default {"DarkYellow"} }
        Write-Host ("  {0,-24} {1}" -f $row.Action, $row.Key) -ForegroundColor $color
    }
    if ($preserved.Count -gt 0) {
        Write-Host ""
        Write-Host "Preserved (untouched by this install):" -ForegroundColor DarkGray
        foreach ($p in $preserved) { Write-Host "  $p" -ForegroundColor DarkGray }
    }
    Write-Host "Edit any of these in Main Menu > Cyber Engine Tweaks > Bindings > HeadTracking." -ForegroundColor DarkGray
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

# Find game installation
$gameDir = Find-GameInstallation -CustomPath $GamePath
if (-not $gameDir) {
    Write-Fail "Cyberpunk 2077 installation not found!"
    Write-Host ""
    Write-Host "Detection order: CYBERPUNK_2077_PATH env var -> Steam appmanifest 1091500 ->" -ForegroundColor Yellow
    Write-Host "Steam folder 'Cyberpunk 2077' -> GOG registry -> Epic paths." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "To specify a custom path, run:" -ForegroundColor Yellow
    Write-Host "  .\deploy.ps1 -GamePath ""D:\Your\Game\Path""" -ForegroundColor Cyan
    exit 1
}
Write-Info "Found Cyberpunk 2077 at: $gameDir"

# Auto-install the bundled CET loader if the user doesn't already have one.
Install-VendoredLoader -SourceDir $sourceDir -GameDir $gameDir -Slug 'cet' `
    -DetectRelPath 'bin\x64\plugins\cyber_engine_tweaks.asi' -DisplayName 'Cyber Engine Tweaks' | Out-Null

# TweakXL applies the projectile restoration. Automatic fire cannot decouple
# without it, so it is a hard requirement rather than an optional extra.
Install-VendoredLoader -SourceDir $sourceDir -GameDir $gameDir -Slug 'tweakxl' `
    -DetectRelPath 'red4ext\plugins\TweakXL\TweakXL.dll' -DisplayName 'TweakXL' | Out-Null

# Validate CET installation
$cetDir = Validate-CETInstallation -GameDir $gameDir
if (-not $cetDir) {
    Write-Fail "Cyber Engine Tweaks (CET) not found!"
    Write-Host ""
    Write-Host "CET is required for this mod to work. Installation steps:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  1. Download the latest release from:" -ForegroundColor White
    Write-Host "     https://github.com/maximegmd/CyberEngineTweaks/releases" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  2. Extract the zip contents to your game folder:" -ForegroundColor White
    Write-Host "     $gameDir" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  3. Verify installation - you should have:" -ForegroundColor White
    Write-Host "     $gameDir\bin\x64\plugins\cyber_engine_tweaks\" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  4. Launch the game and press ~ or Home to verify CET console opens" -ForegroundColor White
    Write-Host ""
    Write-Host "  5. Re-run this deploy script" -ForegroundColor White
    Write-Host ""
    Write-Host "Alternative: Install via Vortex from https://www.nexusmods.com/cyberpunk2077/mods/107" -ForegroundColor DarkGray
    exit 1
}
Write-Info "Found CET at: $cetDir"

# RedSocket is no longer required - the native plugin receives UDP directly.

# Deploy CET mod
$modDir = Join-Path $cetDir "mods\HeadTracking"
Write-Info "Deploying CET mod to: $modDir"

$result = Deploy-Mod -SourceDir $sourceDir -TargetDir $modDir
if (-not $result) {
    Write-Fail "Deployment failed!"
    exit 1
}

# Seed / migrate CET hotkey bindings so Home/End/PageUp/Insert/PageDown work
# without the user having to open the CET bindings UI.
Write-Host ""
Write-Info "Merging HeadTracking hotkey defaults into CET bindings.json..."
Merge-CetBindings -CetDir $cetDir

# Auto-install the bundled RED4ext loader so the native aim plugin loads.
Install-VendoredLoader -SourceDir $sourceDir -GameDir $gameDir -Slug 'red4ext' `
    -DetectRelPath 'red4ext\RED4ext.dll' -DisplayName 'RED4ext' | Out-Null

# Deploy native RED4ext plugin (optional - for aim compensation)
Write-Host ""
Write-Info "Checking for native aim compensation plugin..."
$nativeDeployed = Deploy-NativePlugin -SourceDir $sourceDir -GameDir $gameDir
Deploy-Tweaks -SourceDir $sourceDir -GameDir $gameDir | Out-Null

Write-Host ""
Write-Success "Mod deployed successfully!"
if ($nativeDeployed) {
    Write-Success "Native aim compensation plugin deployed (requires RE hook address)"
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
Write-Host "If the game is already running, fully exit it so CET re-reads bindings.json on next launch." -ForegroundColor DarkGray
Write-Host ""

exit 0
