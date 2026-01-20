@echo off
title OBS Virtual Camera Builder - Logitech C920 Edition
color 0A

echo.
echo ================================================
echo   OBS Virtual Camera - Quick Builder
echo   Custom Name: Logitech HD Pro Webcam C920
echo ================================================
echo.
echo This will build ONLY the Virtual Camera module
echo Estimated time: 3-5 minutes even on slow computers
echo.
echo Press any key to continue...
pause >nul

REM Check for Visual Studio Build Tools
if exist "C:\Program Files (x86)\Microsoft Visual Studio" (
    echo Found Visual Studio!
) else if exist "C:\Program Files\Microsoft Visual Studio" (
    echo Found Visual Studio!
) else (
    echo.
    echo ERROR: Visual Studio not found!
    echo.
    echo Quick fix - Install ONLY what's needed (NOT full Visual Studio):
    echo.
    echo 1. Download this: https://aka.ms/vs/17/release/vs_BuildTools.exe
    echo 2. Run it
    echo 3. Select: "Desktop development with C++"
    echo 4. Install (about 2-3 GB, 10 minutes)
    echo 5. Run this script again
    echo.
    pause
    exit /b 1
)

REM Check for CMake
where cmake >nul 2>&1
if errorlevel 1 (
    echo.
    echo ERROR: CMake not found!
    echo.
    echo Quick fix:
    echo 1. Download: https://github.com/Kitware/CMake/releases/download/v3.30.0/cmake-3.30.0-windows-x86_64.zip
    echo 2. Extract to C:\cmake
    echo 3. Add C:\cmake\bin to your PATH
    echo    - Search "Environment Variables" in Windows
    echo    - Edit PATH
    echo    - Add C:\cmake\bin
    echo 4. Run this script again
    echo.
    pause
    exit /b 1
)

echo.
echo ================================================
echo   Starting build... (grab a coffee!)
echo ================================================
echo.

cd /d "%~dp0"

REM Build script
echo [1/4] Setting up Visual Studio environment...
call "%ProgramFiles%\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat" 2>nul
if errorlevel 1 call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" 2>nul
if errorlevel 1 call "%ProgramFiles%\Microsoft Visual Studio\2019\BuildTools\VC\Auxiliary\Build\vcvars64.bat" 2>nul
if errorlevel 1 call "%ProgramFiles%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat" 2>nul

echo [2/4] Preparing build directories...
if not exist "build-cross" mkdir build-cross
cd build-cross

echo [3/4] Building dependencies (this takes a minute)...

REM Build shared-memory-queue
cmake -G "Visual Studio 17 2022" -A x64 ^
    -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -B . -S "../shared/obs-shared-memory-queue"

if errorlevel 1 (
    echo Failed to configure shared-memory-queue
    pause
    exit /b 1
)

cmake --build . --config RelWithDebInfo --target obs-shared-memory-queue

echo [4/4] Building Virtual Camera module...

cd ../plugins/win-dshow/virtualcam-module
cmake -G "Visual Studio 17 2022" -A x64 ^
    -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB ^
    -DCMAKE_BUILD_TYPE=RelWithDebInfo ^
    -B build -S .

if errorlevel 1 (
    echo Failed to configure virtualcam module
    pause
    exit /b 1
)

cmake --build build --config RelWithDebInfo --parallel

echo.
echo ================================================
echo   BUILD COMPLETE!
echo ================================================
echo.
echo Looking for output file...
dir /s /b build\RelWithDebInfo\*.dll

if exist "build\RelWithDebInfo\obs-virtualcam-module.dll" (
    echo.
    echo SUCCESS! DLL created at:
    echo   build\RelWithDebInfo\obs-virtualcam-module.dll
    echo.
    echo To install:
    echo 1. Copy this file to:
    echo    C:\Program Files\obs-studio\obs-plugins\win-dshow\
    echo 2. Run OBS as Administrator
    echo 3. Start Virtual Camera
    echo 4. Check Device Manager - should show "Logitech HD Pro Webcam C920"
) else (
    echo.
    echo ERROR: DLL not found! Check above for errors.
)

echo.
pause
