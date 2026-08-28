@echo off
:: ============================================
:: HeadTracking (Cyberpunk 2077) - Install
:: ============================================
:: Skeleton from cameraunlock-core/scripts/templates/install.cmd. No CET
:: template exists: this mod deploys a Lua tree under
:: bin\x64\plugins\cyber_engine_tweaks\mods\, a RED4ext native plugin and a
:: TweakXL yaml, and it vendors three loaders (CET, RED4ext, TweakXL). All of
:: that lives in deploy.ps1, which we forward to once GAME_PATH is resolved,
:: so there is no MOD_DLLS list here - deploy.ps1 and launcher-manifest.json
:: are the authoritative file lists.
:: ============================================

:: --- CONFIG BLOCK ---
set "GAME_ID=cyberpunk-2077"
set "MOD_DISPLAY_NAME=HeadTracking (Cyberpunk 2077)"
set "MOD_INTERNAL_NAME=HeadTracking"
set "MOD_VERSION=1.3.3"
set "MOD_CONTROLS=Controls:&echo   End       - Toggle head tracking on/off&echo   Page Up   - Cycle tracking mode&echo   Page Down - Toggle world/local yaw"
set "STATE_FILE=.headtracking-state.json"
:: CET, RED4ext and TweakXL are shared modding frameworks that uninstall never
:: removes, so the state file records "None" - the uninstall template's
:: framework dispatch has no CET/RED4ext case and must not try to remove one.
set "FRAMEWORK_TYPE=None"
:: --- END CONFIG BLOCK ---

call :detect_yes_flag %*
call :main %*
set "_EC=%errorlevel%"
if not defined YES_FLAG ( echo. & pause )
exit /b %_EC%

:: ============================================
:: Pre-scan args at outer scope so YES_FLAG propagates to the post-:main
:: pause check. :main's arg parser sets its own (local) YES_FLAG too, but
:: cmd.exe discards local vars when setlocal pops on `exit /b`, so without
:: this pre-scan the post-:main `if not defined YES_FLAG` always pauses
:: and /y can't make the script headless. Quoted-string form is required
:: here - bracket form `if [%~1]==[/y]` does NOT quote, so a path arg
:: containing whitespace ("C:\...\Gone Home") splits across the brackets
:: and crashes cmd with "[Home]==[/y] was unexpected at this time". The
:: trailing-backslash hazard the bracket form was working around is moot
:: with `%~1`: it strips the launcher's surrounding quotes before the
:: comparison, so a value like `C:\foo\` can't escape the closing `"`.
:: ============================================
:detect_yes_flag
if "%~1"=="" exit /b 0
if /i "%~1"=="/y"    set "YES_FLAG=1"
if /i "%~1"=="-y"    set "YES_FLAG=1"
if /i "%~1"=="--yes" set "YES_FLAG=1"
shift
goto :detect_yes_flag

:main
setlocal enabledelayedexpansion

:: Capture script dir BEFORE the arg parser runs. Inside `call :main`,
:: `shift` rotates %0 too, so %~dp0 read after shifts resolves to the
:: dirname of the first arg (e.g. C:\ for /y) instead of the script.
set "SCRIPT_DIR=%~dp0"

:: -------- Arg parser (canonical, do not modify) --------
set "YES_FLAG="
set "UPGRADE_FLAG="
set "_GIVEN_PATH="
:parse_args
if "%~1"=="" goto :args_done
set "_ARG=%~1"
if /i "!_ARG!"=="/y"    ( set "YES_FLAG=1" & shift & goto :parse_args )
if /i "!_ARG!"=="-y"    ( set "YES_FLAG=1" & shift & goto :parse_args )
if /i "!_ARG!"=="--yes" ( set "YES_FLAG=1" & shift & goto :parse_args )
if /i "!_ARG!"=="/upgrade-deps"  ( set "UPGRADE_FLAG=1" & shift & goto :parse_args )
if /i "!_ARG!"=="--upgrade-deps" ( set "UPGRADE_FLAG=1" & shift & goto :parse_args )
if "!_ARG:~0,2!"=="--" ( echo ERROR: unknown flag "!_ARG!" & exit /b 2 )
if "!_ARG:~0,1!"=="/"  ( echo ERROR: unknown flag "!_ARG!" & exit /b 2 )
if "!_ARG:~0,1!"=="-"  ( echo ERROR: unknown flag "!_ARG!" & exit /b 2 )
if not defined _GIVEN_PATH (
    if exist "!_ARG!\" ( set "_GIVEN_PATH=!_ARG!" & shift & goto :parse_args )
)
echo ERROR: unrecognised argument "!_ARG!"
exit /b 2
:args_done

echo.
echo === %MOD_DISPLAY_NAME% - Install ===
echo.

:: -------- Resolve game path via shared shim --------
:: Release ZIP layout: scripts\ is the ZIP root, shim is at shared\find-game.ps1.
:: Dev tree layout: scripts\ is <repo>\scripts\, shim is at ..\cameraunlock-core\scripts\find-game.ps1.
set "_SHIM=%SCRIPT_DIR%shared\find-game.ps1"
if not exist "%_SHIM%" set "_SHIM=%SCRIPT_DIR%..\cameraunlock-core\scripts\find-game.ps1"
if not exist "%_SHIM%" (
    echo ERROR: find-game.ps1 not found in shared\ or ..\cameraunlock-core\scripts\.
    echo If this is a release ZIP, re-download it from GitHub ^(corrupt installer^).
    echo If this is the dev tree, make sure the cameraunlock-core submodule is checked out.
    exit /b 1
)
set "_SHIM_OUT=%TEMP%\cul-find-%RANDOM%-%RANDOM%.cmd"
set "_GIVEN_ARG="
if defined _GIVEN_PATH set "_GIVEN_ARG=-GivenPath "!_GIVEN_PATH!""
powershell -NoProfile -ExecutionPolicy Bypass -File "%_SHIM%" -GameId %GAME_ID% -OutFile "!_SHIM_OUT!" !_GIVEN_ARG!
set "_PS_EC=!errorlevel!"
if not "!_PS_EC!"=="0" (
    echo.
    echo ERROR: Could not resolve game install path ^(shim exit code !_PS_EC!^).
    echo Pass a path explicitly: install.cmd "C:\path\to\game"
    echo.
    del "!_SHIM_OUT!" 2>nul
    exit /b 1
)
call "!_SHIM_OUT!"
del "!_SHIM_OUT!" 2>nul

:: The shim accepts any existing directory as an explicit -GivenPath without
:: looking for the EXE inside it, so confirm before announcing "Game found" -
:: otherwise a mistyped path reads as a successful detection and only fails
:: several steps later, out of deploy.ps1.
if not exist "%GAME_PATH%\%GAME_EXE_RELPATH%" (
    echo.
    echo ERROR: No %GAME_EXE% found under:
    echo   %GAME_PATH%
    echo.
    echo That folder is not a %GAME_DISPLAY_NAME% installation. Pass the folder
    echo that contains bin\x64\%GAME_EXE%.
    echo.
    echo If the folder does look right, Windows may be denying access to it -
    echo right-click install.cmd and choose "Run as administrator".
    echo.
    exit /b 1
)

echo Game found: "%GAME_PATH%"
echo.

:: -------- Game-running check --------
tasklist /fi "imagename eq %GAME_EXE%" 2>nul | findstr /i "%GAME_EXE%" >nul 2>&1
if not errorlevel 1 (
    echo ERROR: %GAME_DISPLAY_NAME% is currently running.
    echo Please close the game before installing.
    echo.
    exit /b 1
)

:: -------- Write-permission check --------
:: Epic installs to C:\Program Files\Epic Games\ by default, which is not
:: user-writable. Without this the first thing the user sees is a PowerShell
:: UnauthorizedAccessException stack trace out of Expand-Archive, which reads
:: like the installer is broken rather than like it needs elevating.
set "_WTEST=%GAME_PATH%\.headtracking-write-test.tmp"
( break > "%_WTEST%" ) 2>nul
if not exist "%_WTEST%" (
    echo.
    echo ERROR: No write access to the game folder:
    echo   %GAME_PATH%
    echo.
    echo Installing a mod means writing files into that folder, and Windows is
    echo refusing. Close the game and any launcher, then right-click install.cmd
    echo and choose "Run as administrator".
    echo.
    exit /b 1
)
del "%_WTEST%" 2>nul

:: -------- Locate deploy.ps1 --------
:: Release ZIP layout: scripts\deploy.ps1. Repo layout: same path.
set "DEPLOY_PS1=%SCRIPT_DIR%deploy.ps1"
if not exist "%DEPLOY_PS1%" set "DEPLOY_PS1=%SCRIPT_DIR%scripts\deploy.ps1"
if not exist "%DEPLOY_PS1%" (
    echo ERROR: deploy.ps1 not found next to install.cmd.
    echo If this is a release ZIP, re-download it from GitHub ^(corrupt installer^).
    exit /b 1
)

:: -------- Prior state: preserve installed_by_us=true across re-installs --------
:: deploy.ps1 extracts the vendored loaders when they are absent, but they are
:: shared frameworks other mods depend on and uninstall never removes them, so
:: this mod does not claim ownership of them.
set "WE_INSTALLED=false"
if exist "%GAME_PATH%\%STATE_FILE%" (
    findstr /c:"installed_by_us" "%GAME_PATH%\%STATE_FILE%" 2>nul | findstr /c:"true" >nul 2>&1
    if not errorlevel 1 set "WE_INSTALLED=true"
)

:: -------- Forward to deploy.ps1 --------
echo Running deploy.ps1...
echo.
set "_DEPLOY_ARGS="
if defined YES_FLAG     set "_DEPLOY_ARGS=!_DEPLOY_ARGS! -AssumeYes"
if defined UPGRADE_FLAG set "_DEPLOY_ARGS=!_DEPLOY_ARGS! -UpgradeLoaders"
powershell -NoProfile -ExecutionPolicy Bypass -File "%DEPLOY_PS1%" -GamePath "%GAME_PATH%"!_DEPLOY_ARGS!
set "_DEPLOY_EC=!errorlevel!"
if not "!_DEPLOY_EC!"=="0" (
    echo.
    echo ERROR: deploy.ps1 failed with exit code !_DEPLOY_EC!.
    exit /b !_DEPLOY_EC!
)

:: -------- Write state file --------
call :write_state_file

echo.
echo ========================================
echo   Deployment Complete!
echo ========================================
echo.
echo %MOD_DISPLAY_NAME% has been deployed to:
echo   %GAME_PATH%\bin\x64\plugins\cyber_engine_tweaks\mods\%MOD_INTERNAL_NAME%
echo.
echo Start the game to use the mod!
:: Percent-expansion splits MOD_CONTROLS on its embedded &echo separators;
:: delayed expansion prints them literally. Kept outside a ( ) block so a
:: literal ) in the controls text cannot close the block.
if not defined MOD_CONTROLS goto :controls_done
echo.
echo %MOD_CONTROLS%
:controls_done
echo.
exit /b 0

:: ============================================
:: Write the canonical state file.
:: Schema version 1. Preserves WE_INSTALLED which may have been
:: already-true from a prior install.
:: ============================================
:write_state_file
> "%GAME_PATH%\%STATE_FILE%" (
    echo {
    echo   "schema_version": 1,
    echo   "framework": {
    echo     "type": "%FRAMEWORK_TYPE%",
    echo     "installed_by_us": !WE_INSTALLED!
    echo   },
    echo   "mod": {
    echo     "id": "%GAME_ID%",
    echo     "name": "%MOD_INTERNAL_NAME%",
    echo     "version": "%MOD_VERSION%"
    echo   }
    echo }
)
exit /b 0
