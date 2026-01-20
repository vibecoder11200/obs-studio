# OBS Virtual Camera - Logitech HD Pro Webcam C920

Custom Virtual Camera module for OBS Studio that appears as "Logitech HD Pro Webcam C920" in Windows.

## Changes Made

- **Camera Name**: `OBS Virtual Camera` → `Logitech HD Pro Webcam C920`
- **Unique GUID**: `76692E1E-F28F-4DD6-9024-C3A999D30EFB` (different from OBS original)
- **File Description**: Updated to reflect custom camera name

## How to Build

### Prerequisites

You need **Windows** with one of the following:
- Visual Studio 2022 (Community/Enterprise)
- Visual Studio 2019 (Community/Enterprise)
- CMake (3.28 or later)
- Git

### Quick Build

1. **Clone this repository:**
   ```cmd
   git clone https://github.com/vibecoder11200/obs-studio.git
   cd obs-studio
   ```

2. **Run the build script:**
   ```cmd
   build-virtualcam.bat
   ```

3. **Find output files in:**
   ```
   output\obs-virtualcam-module.dll
   output\obs-virtualcam-install.bat
   output\obs-virtualcam-uninstall.bat
   ```

### Manual Build (if script fails)

```cmd
cd plugins\win-dshow\virtualcam-module

cmake -B build -S . -G "Visual Studio 17 2022" -A x64 ^
  -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB

cmake --build build --config RelWithDebInfo --parallel
```

Output will be in: `build\RelWithDebInfo\obs-virtualcam-module.dll`

## Installation

### Method 1: Replace DLL (Recommended)

1. **Close OBS Studio** if running

2. **Navigate to OBS plugins directory:**
   ```
   C:\Program Files\obs-studio\obs-plugins\win-dshow\
   ```

3. **Backup original DLL:**
   ```cmd
   copy obs-virtualcam-module.dll obs-virtualcam-module.dll.backup
   ```

4. **Copy custom DLL:**
   ```cmd
   copy path\to\output\obs-virtualcam-module.dll .
   ```

5. **Run OBS as Administrator** and start Virtual Camera

### Method 2: Register Manually

1. Open **Command Prompt as Administrator**

2. Navigate to output directory:
   ```cmd
   cd path\to\output
   ```

3. Register the DLL:
   ```cmd
   regsvr32 /s obs-virtualcam-module.dll
   ```

## Verification

### Check in Device Manager

1. Open Device Manager (Win+X, M)
2. Expand **Camera** or **Sound, video and game controllers**
3. Look for **"Logitech HD Pro Webcam C920"**

### Check in Apps

1. Open Zoom/Teams/Skype/etc.
2. Go to Camera Settings
3. Select **"Logitech HD Pro Webcam C920"**
4. Start OBS Virtual Camera
5. Test camera feed

## Uninstallation

### Restore Original DLL

1. Close OBS Studio
2. Navigate to `C:\Program Files\obs-studio\obs-plugins\win-dshow\`
3. Delete `obs-virtualcam-module.dll`
4. Rename `obs-virtualcam-module.dll.backup` → `obs-virtualcam-module.dll`
5. Run OBS as Administrator

### Unregister DLL

```cmd
regsvr32 /u /s obs-virtualcam-module.dll
```

## Troubleshooting

### "Camera not found" error

- Make sure OBS is running as **Administrator**
- Restart OBS after replacing DLL
- Check Windows Event Viewer for errors

### "Access Denied" error

- Run Command Prompt as Administrator
- Make sure OBS is closed before replacing files

### Camera shows as "OBS Virtual Camera" (old name)

- Old DLL might still be registered
- Unregister old DLL: `regsvr32 /u obs-virtualcam-module.dll`
- Restart Windows
- Register new DLL

### GUID Conflicts

If you have multiple OBS Virtual Cameras installed:
1. Unregister ALL virtual camera DLLs
2. Restart Windows
3. Install only this custom version

## Technical Details

### GUID Information

- **Original OBS GUID**: `A3FCE0F5-3493-419F-958A-ABA1250EC20B`
- **Custom GUID**: `76692E1E-F28F-4DD6-9024-C3A999D30EFB`

The custom GUID ensures this virtual camera doesn't conflict with the original OBS installation.

### Files Modified

1. `CMakePresets.json` - Updated GUID for Windows builds
2. `plugins/win-dshow/virtualcam-module/virtualcam-module.cpp` - Changed camera name
3. `plugins/win-dshow/virtualcam-module/cmake/windows/obs-module.rc.in` - Updated file description

## Notes

- **UI remains unchanged**: OBS interface still shows "Virtual Camera" - only Windows device name changes
- **Safe to use**: Different GUID prevents conflicts with official OBS builds
- **Reversible**: Can always restore original DLL

## Credits

Based on OBS Studio Virtual Camera:
- https://github.com/obsproject/obs-studio
- Licensed under GNU General Public License v2

## License

This modification follows the same license as OBS Studio (GPLv2).
