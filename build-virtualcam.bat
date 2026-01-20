@echo off
REM Build Script for OBS Virtual Camera Module
REM Customized with Logitech HD Pro Webcam C920

echo ========================================
echo OBS Virtual Camera Builder
echo Custom: Logitech HD Pro Webcam C920
echo GUID: 76692E1E-F28F-4DD6-9024-C3A999D30EFB
echo ========================================
echo.

REM Check if running on Windows
ver | findstr /i "windows" >nul
if errorlevel 1 (
    echo ERROR: This script must be run on Windows!
    pause
    exit /b 1
)

REM Check for Visual Studio
where cl >nul 2>&1
if errorlevel 1 (
    echo Setting up Visual Studio environment...
    call "%ProgramFiles%\Microsoft Visual Studio\2022\Enterprise\VC\Auxiliary\Build\vcvars64.bat" 2>nul
    if errorlevel 1 (
        call "%ProgramFiles%\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat" 2>nul
        if errorlevel 1 (
            call "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Enterprise\VC\Auxiliary\Build\vcvars64.bat" 2>nul
            if errorlevel 1 (
                call "%ProgramFiles(x86)%\Microsoft Visual Studio\2019\Community\VC\Auxiliary\Build\vcvars64.bat" 2>nul
                if errorlevel 1 (
                    echo ERROR: Visual Studio not found!
                    echo Please install Visual Studio 2019 or 2022 with C++ support
                    pause
                    exit /b 1
                )
            )
        )
    )
)

echo Visual Studio environment ready
echo.

REM Check for CMake
where cmake >nul 2>&1
if errorlevel 1 (
    echo ERROR: CMake not found!
    echo Please install CMake and add it to PATH
    pause
    exit /b 1
)

echo CMake found
echo.

REM Set build directories
set BUILD_DIR=build_virtualcam
set SOURCE_DIR=%~dp0

echo ========================================
echo Starting build...
echo ========================================
echo.

REM Configure
echo [1/3] Configuring CMake...
cd /d "%SOURCE_DIR%"
cmake -B "%BUILD%" -S plugins\win-dshow\virtualcam-module ^
    -G "Visual Studio 17 2022" -A x64 ^
    -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB

if errorlevel 1 (
    echo.
    echo ERROR: CMake configuration failed!
    pause
    exit /b 1
)

echo.
echo [2/3] Building Virtual Camera module...
cmake --build "%BUILD%\plugins\win-dshow\virtualcam-module" --config RelWithDebInfo --parallel

if errorlevel 1 (
    echo.
    echo ERROR: Build failed!
    pause
    exit /b 1
)

echo.
echo [3/3] Copying files to output directory...
if not exist "output" mkdir output
copy /Y "%BUILD%\plugins\win-dshow\virtualcam-module\RelWithDebInfo\obs-virtualcam-module.dll" output\ >nul
copy /Y "%BUILD%\plugins\win-dshow\virtualcam-module\obs-virtualcam-install.bat" output\ >nul 2>&1
copy /Y "%BUILD%\plugins\win-dshow\virtualcam-module\obs-virtualcam-uninstall.bat" output\ >nul 2>&1

echo.
echo ========================================
echo BUILD SUCCESSFUL!
echo ========================================
echo.
echo Output files:
echo   - output\obs-virtualcam-module.dll
echo   - output\obs-virtualcam-install.bat (if available)
echo   - output\obs-virtualcam-uninstall.bat (if available)
echo.
echo Next steps:
echo   1. Close OBS Studio if running
echo   2. Go to your OBS installation directory
echo      Typically: C:\Program Files\obs-studio
echo   3. Navigate to: obs-plugins\win-dshow\
echo   4. Backup the original obs-virtualcam-module.dll
echo   5. Copy output\obs-virtualcam-module.dll to that location
echo   6. Run OBS as Administrator
echo   7. Start Virtual Camera from OBS
echo   8. Check in Device Manager - should appear as "Logitech HD Pro Webcam C920"
echo.
pause
