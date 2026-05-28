@echo off
setlocal enabledelayedexpansion

:: Find Visual Studio installation
set "VCVARS="
if exist "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
) else if exist "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat" (
    set "VCVARS=C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat"
)

if "!VCVARS!"=="" (
    echo ERROR: Could not find Visual Studio installation
    exit /b 1
)

echo Using Visual Studio: !VCVARS!
call "!VCVARS!"
if errorlevel 1 (
    echo ERROR: Failed to initialize Visual Studio environment
    exit /b 1
)

:: Create build directory if needed
cd /d "%~dp0"
if not exist "build" mkdir build

:: Configure. If the cache was generated against a different source path (e.g.
:: the repo was moved or renamed), CMake refuses to re-use it and errors out.
:: Retry once after wiping the build dir so `pixi run install` just works
:: instead of needing a manual `pixi run clean`.
echo Configuring with CMake...
cmake -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release -S . -B build
if errorlevel 1 (
    echo CMake configure failed - likely stale cache from a prior source path. Cleaning and retrying...
    rmdir /s /q build
    mkdir build
    cmake -G "NMake Makefiles" -DCMAKE_BUILD_TYPE=Release -S . -B build
    if errorlevel 1 (
        echo ERROR: CMake configuration failed after clean retry
        exit /b 1
    )
)

cd build

:: Build
echo Building...
nmake
if errorlevel 1 (
    echo ERROR: Build failed
    exit /b 1
)

echo.
echo Build successful!
echo Output: %CD%\bin\HeadTrackingAim.dll
