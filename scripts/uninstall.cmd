@echo off
:: ============================================
:: HeadTracking (Cyberpunk 2077) - Uninstall
:: ============================================
:: Skeleton from cameraunlock-core/scripts/templates/uninstall.cmd. The
:: actual file removal lives in uninstall.ps1; we just resolve GAME_PATH
:: via the shared shim and forward. CET is a shared loader: even with
:: /force we never remove it (other mods may depend on it).
:: ============================================

:: --- CONFIG BLOCK ---
set "GAME_ID=cyberpunk-2077"
set "MOD_DISPLAY_NAME=HeadTracking (Cyberpunk 2077)"
set "MOD_INTERNAL_NAME=HeadTracking"
set "STATE_FILE=.headtracking-state.json"
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
set "FORCE_FLAG="
set "_GIVEN_PATH="
:parse_args
if "%~1"=="" goto :args_done
set "_ARG=%~1"
if /i "!_ARG!"=="/y"      ( set "YES_FLAG=1"   & shift & goto :parse_args )
if /i "!_ARG!"=="-y"      ( set "YES_FLAG=1"   & shift & goto :parse_args )
if /i "!_ARG!"=="--yes"   ( set "YES_FLAG=1"   & shift & goto :parse_args )
if /i "!_ARG!"=="/force"  ( set "FORCE_FLAG=1" & shift & goto :parse_args )
if /i "!_ARG!"=="--force" ( set "FORCE_FLAG=1" & shift & goto :parse_args )
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
echo === %MOD_DISPLAY_NAME% - Uninstall ===
echo.

:: -------- Resolve game path via shared shim --------
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
    echo Pass a path explicitly: uninstall.cmd "C:\path\to\game"
    echo.
    del "!_SHIM_OUT!" 2>nul
    exit /b 1
)
call "!_SHIM_OUT!"
del "!_SHIM_OUT!" 2>nul

echo Game found: %GAME_PATH%
echo.

:: -------- Game-running check --------
tasklist /fi "imagename eq %GAME_EXE%" 2>nul | findstr /i "%GAME_EXE%" >nul 2>&1
if not errorlevel 1 (
    echo ERROR: %GAME_DISPLAY_NAME% is currently running.
    echo Please close the game before uninstalling.
    echo.
    exit /b 1
)

:: -------- Locate uninstall.ps1 --------
set "UNINSTALL_PS1=%SCRIPT_DIR%uninstall.ps1"
if not exist "%UNINSTALL_PS1%" set "UNINSTALL_PS1=%SCRIPT_DIR%scripts\uninstall.ps1"
if not exist "%UNINSTALL_PS1%" (
    echo ERROR: uninstall.ps1 not found next to uninstall.cmd.
    echo If this is a release ZIP, re-download it from GitHub ^(corrupt installer^).
    exit /b 1
)

:: -------- Forward to uninstall.ps1 --------
echo Running uninstall.ps1...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%UNINSTALL_PS1%" -GamePath "%GAME_PATH%"
set "_UN_EC=!errorlevel!"
if not "!_UN_EC!"=="0" (
    echo.
    echo ERROR: uninstall.ps1 failed with exit code !_UN_EC!.
    exit /b !_UN_EC!
)

:: CET is shared - never remove it. /force is parsed for launcher consistency
:: but does not change behaviour here.
if "!FORCE_FLAG!"=="1" (
    echo.
    echo Cyber Engine Tweaks is a shared modding framework - leaving intact even with /force ^(other mods may depend on it^).
)

:: -------- Remove state file --------
if exist "%GAME_PATH%\%STATE_FILE%" (
    del "%GAME_PATH%\%STATE_FILE%"
    echo   Removed: state file
)

echo.
echo === Uninstall Complete ===
echo.
exit /b 0
