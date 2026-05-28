@echo off
:: ============================================
:: HeadTracking (Cyberpunk 2077) - DEV launcher
:: ============================================
:: Boots the game with the minimum possible pre-gameplay overhead, for
:: fast iteration loops while debugging the mod. Skips:
::   - REDprelauncher.exe   (the GOG/Steam wrapper window)
::   - GOG Galaxy launcher  (if launched from Galaxy)
::   - Splash logo train    (via -skipStartScreen)
::   - Press-any-key prompt (via -skipStartScreen)
::
:: This complements the existing r6\scripts\NoIntroVideos.reds, which
:: collapses the in-engine logo animations to their post-skip state.
::
:: NOT for end-users. Real installs go through scripts\install.cmd and
:: launch via REDprelauncher so GOG/Steam achievements + cloud saves
:: keep working.
:: ============================================

setlocal enabledelayedexpansion

set "SCRIPT_DIR=%~dp0"
set "PROJECT_ROOT=%SCRIPT_DIR%.."
set "FIND_GAME_PS1=%PROJECT_ROOT%\cameraunlock-core\scripts\find-game.ps1"

if not exist "%FIND_GAME_PS1%" (
    echo ERROR: find-game.ps1 missing at "%FIND_GAME_PS1%".
    exit /b 1
)

set "_SHIM_OUT=%TEMP%\headtracking-devlaunch-%RANDOM%.cmd"
set "_GIVEN_ARG="
if not "%~1"=="" set "_GIVEN_ARG=-GivenPath ""%~1"""

powershell -NoProfile -ExecutionPolicy Bypass -File "%FIND_GAME_PS1%" -GameId cyberpunk-2077 -OutFile "!_SHIM_OUT!" !_GIVEN_ARG!
if errorlevel 1 (
    echo ERROR: could not resolve Cyberpunk 2077 install path.
    if exist "!_SHIM_OUT!" del "!_SHIM_OUT!"
    exit /b 1
)
call "!_SHIM_OUT!"
del "!_SHIM_OUT!"

set "GAME_EXE_FULL=%GAME_PATH%\%GAME_EXE_RELPATH%"
if not exist "%GAME_EXE_FULL%" (
    echo ERROR: game exe not found at "%GAME_EXE_FULL%".
    exit /b 1
)

tasklist /FI "IMAGENAME eq %GAME_EXE%" 2>nul | findstr /i "%GAME_EXE%" >nul
if not errorlevel 1 (
    echo ERROR: %GAME_EXE% is already running. Close it first.
    exit /b 1
)

echo Launching: "%GAME_EXE_FULL%" -skipStartScreen %*
pushd "%GAME_PATH%\bin\x64"
start "" "%GAME_EXE_FULL%" -skipStartScreen %*
popd
exit /b 0
