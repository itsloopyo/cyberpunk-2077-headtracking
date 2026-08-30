@echo off
:: ============================================
:: HeadTracking (Cyberpunk 2077) - Uninstall
:: ============================================
:: Skeleton from cameraunlock-core/scripts/templates/uninstall.cmd. The CET
:: mod folder and the RED4ext native plugin are removed by uninstall.ps1; we
:: resolve GAME_PATH via the shared shim, forward to it, then remove the
:: files it does not cover (MOD_EXTRA_FILES). CET, RED4ext and TweakXL are
:: shared loaders: even with /force we never remove them, since other mods
:: depend on them.
:: ============================================
::
:: Deliberately not a thin wrapper over cameraunlock-core/scripts/uninstall-body.cmd.
:: It dispatches to uninstall.ps1, which unmerges the mod's entries from CET's
:: bindings.json and backs up config.json before removing the Lua tree. CET,
:: RED4ext and TweakXL are shared frameworks and are left intact even with
:: /force. See install.cmd for the full reasoning.

:: --- CONFIG BLOCK ---
set "GAME_ID=cyberpunk-2077"
set "MOD_DISPLAY_NAME=HeadTracking (Cyberpunk 2077)"
set "MOD_INTERNAL_NAME=HeadTracking"
set "STATE_FILE=.headtracking-state.json"
set "FRAMEWORK_TYPE=None"
:: Game-relative files deployed outside the CET mod folder. The TweakXL yaml
:: rewrites the bullet records, so leaving it behind keeps altering gameplay
:: after an uninstall. No LEGACY_DLLS: no shipped file has ever been renamed
:: or dropped.
set "MOD_EXTRA_FILES=r6\tweaks\HeadTracking_ProjectileBullets.yaml"
:: --- END CONFIG BLOCK ---

:: Pin delayed expansion off before `%*` is expanded on the `call` below.
:: Under `cmd /V:ON`, or with DelayedExpansion=1 in
:: HKCU\Software\Microsoft\Command Processor, cmd.exe eats a `!` out of the
:: expanded line, and a real game path like C:\Games\Oh! My Game reaches the
:: body already mangled. The body pins expansion off at its own outer scope
:: too, but that is one `call` too late to save the argument it was handed.
setlocal disabledelayedexpansion

set "WRAPPER_DIR=%~dp0"
set "_BODY=%WRAPPER_DIR%shared\uninstall-body.cmd"
if not exist "%_BODY%" set "_BODY=%WRAPPER_DIR%..\cameraunlock-core\scripts\uninstall-body.cmd"
if not exist "%_BODY%" (
    echo ERROR: uninstall-body.cmd not found in shared\ or ..\cameraunlock-core\scripts\.
    echo If this is a release ZIP, re-download it from GitHub ^(corrupt installer^).
    echo If this is the dev tree, run: git submodule update --init --recursive
    exit /b 1
)
call "%_BODY%" %*
exit /b %errorlevel%