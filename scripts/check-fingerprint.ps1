<#
.SYNOPSIS
    Print the PE fingerprint of an installed Cyberpunk2077.exe.

.DESCRIPTION
    The native plugin pins several hooks to hardcoded RVAs derived from one
    specific shipped build. It routes those RVAs through a build-profile
    registry keyed on the EXE's PE fingerprint (TimeDateStamp + SizeOfImage +
    CheckSum) and stays dormant on a build it does not recognise.

    This script reads the fingerprint off a game EXE on disk and prints a
    paste-ready profile stub for native/src/builds/. It is the first thing to
    run when a user reports the "unknown build" log line, and the first step of
    a rederive after a game patch.

.PARAMETER GamePath
    Game install root. Auto-detected when omitted.

.PARAMETER ExePath
    Path straight to a Cyberpunk2077.exe, bypassing game-path detection.

.EXAMPLE
    pixi run check-fingerprint
    .\check-fingerprint.ps1 -GamePath "D:\Games\Cyberpunk 2077"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$GamePath,

    [Parameter(Mandatory = $false)]
    [string]$ExePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Info { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Fail { param([string]$Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

if (-not $ExePath) {
    if (-not $GamePath) {
        $projectRoot = Split-Path -Parent $PSScriptRoot
        $gpdCandidates = @(
            (Join-Path $projectRoot 'cameraunlock-core/powershell/GamePathDetection.psm1'),
            (Join-Path $projectRoot 'shared/GamePathDetection.psm1')
        )
        $gpdPath = $gpdCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
        if (-not $gpdPath) {
            Write-Fail "GamePathDetection.psm1 not found - pass -GamePath or -ExePath explicitly."
            exit 1
        }
        Import-Module $gpdPath -Force
        $GamePath = Find-GamePath -GameId 'cyberpunk-2077'
        if (-not $GamePath) {
            Write-Fail "Cyberpunk 2077 not found - pass -GamePath or -ExePath explicitly."
            exit 1
        }
    }
    $ExePath = Join-Path $GamePath 'bin\x64\Cyberpunk2077.exe'
}

if (-not (Test-Path -LiteralPath $ExePath)) {
    Write-Fail "No EXE at: $ExePath"
    exit 1
}

# PE32+ layout. The optional header starts right after the 20-byte COFF header;
# SizeOfImage sits at +0x38 into it and CheckSum at +0x40. Reading those two at
# the PE32 offsets instead is the classic way to produce a fingerprint that
# looks plausible and matches nothing.
$stream = [System.IO.File]::OpenRead($ExePath)
try {
    $reader = New-Object System.IO.BinaryReader($stream)

    $stream.Seek(0x3C, 'Begin') | Out-Null
    $peOffset = $reader.ReadInt32()

    $stream.Seek($peOffset, 'Begin') | Out-Null
    if ($reader.ReadUInt32() -ne 0x00004550) {
        Write-Fail "Not a PE image: $ExePath"
        exit 1
    }

    $machine = $reader.ReadUInt16()
    $null = $reader.ReadUInt16()          # NumberOfSections
    $timeDateStamp = $reader.ReadUInt32()

    $optionalHeader = $peOffset + 0x18
    $stream.Seek($optionalHeader, 'Begin') | Out-Null
    $magic = $reader.ReadUInt16()
    if ($magic -ne 0x20B) {
        Write-Fail ("Expected a PE32+ image (optional header magic 0x20B), got 0x{0:X}" -f $magic)
        exit 1
    }

    $stream.Seek($optionalHeader + 0x38, 'Begin') | Out-Null
    $sizeOfImage = $reader.ReadUInt32()

    $stream.Seek($optionalHeader + 0x40, 'Begin') | Out-Null
    $checkSum = $reader.ReadUInt32()
}
finally {
    $stream.Close()
}

$item = Get-Item -LiteralPath $ExePath
$built = [DateTimeOffset]::FromUnixTimeSeconds($timeDateStamp).UtcDateTime
$profileDate = $built.ToString('yyyyMMdd')

Write-Host ""
Write-Host "========================================" -ForegroundColor Yellow
Write-Host "  Cyberpunk2077.exe build fingerprint" -ForegroundColor Yellow
Write-Host "========================================" -ForegroundColor Yellow
Write-Host ""
Write-Info "EXE            : $ExePath"
Write-Info "FileVersion    : $($item.VersionInfo.FileVersion)"
Write-Info "ProductVersion : $($item.VersionInfo.ProductVersion)"
Write-Info ("Machine        : 0x{0:X4}" -f $machine)
Write-Host ""
Write-Host ("  TimeDateStamp = 0x{0:X8}   ({1:yyyy-MM-dd HH:mm:ss} UTC)" -f $timeDateStamp, $built) -ForegroundColor Green
Write-Host ("  SizeOfImage   = 0x{0:X8}" -f $sizeOfImage) -ForegroundColor Green
Write-Host ("  CheckSum      = 0x{0:X8}" -f $checkSum) -ForegroundColor Green
Write-Host ""
Write-Host "Paste-ready profile stub (native/src/builds/<store>_offsets.cpp):" -ForegroundColor Yellow
Write-Host ""

$stub = @"
// Game $($item.VersionInfo.ProductVersion), EXE $($item.VersionInfo.FileVersion), built $($built.ToString('yyyy-MM-dd')).
extern const BuildProfile kStoreProfile_$profileDate = {
    "store-win64-$profileDate",
    { 0x$('{0:X8}' -f $timeDateStamp), 0x$('{0:X8}' -f $sizeOfImage), 0x$('{0:X8}' -f $checkSum) },
    {
        0x000000,  // Propagator
        0x000000,  // GetWorldOrientation
        0x000000,  // GetWorldTransform
        0x000000,  // FireNormaliseCall
        0x000000,  // NormaliseFn
    },
};
"@

Write-Host $stub -ForegroundColor White
Write-Host ""
Write-Host "Replace 'store' with steam/gog/epic, fill in the RVAs, and add the profile" -ForegroundColor DarkGray
Write-Host "to the TOP of kKnownProfiles in native/src/builds/build_registry.cpp." -ForegroundColor DarkGray
Write-Host "Never edit an existing profile's numbers - patches get a NEW profile." -ForegroundColor DarkGray
Write-Host ""

exit 0
