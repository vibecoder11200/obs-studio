# OBS Virtual Camera - Logitech HD Pro Webcam C920

Custom Virtual Camera module for OBS Studio that presents itself to Windows
applications as a **Logitech HD Pro Webcam C920**.

**Transparency note:** this fork deliberately impersonates a physical webcam
device name for **app-compatibility purposes** (apps that filter or block
virtual cameras). It does not make the camera undetectable at every level, and
it is not intended to defeat proctoring, KYC or identity checks. Shipping a
build with Logitech branding carries a trademark risk that is accepted by the
fork maintainer; all brand strings are configurable via CMake variables if you
need a neutral build. The same applies to the **runtime identity presets**
offered in the Virtual Camera configuration dialog (real-camera name/VID/PID
bundles) — they present the same trademark exposure.

## Changes Made

- **Camera name**: `OBS Virtual Camera` → `Logitech HD Pro Webcam C920` (configurable via `VIRTUALCAM_BRAND_NAME`)
- **Unique GUID**: `76692E1E-F28F-4DD6-9024-C3A999D30EFB` (different from OBS upstream)
- **DLL name**: `obs-virtualcam-module{64,32}.dll` → `lvc920x64.dll` / `lvc920x86.dll` / `lvc920arm64.dll`
- **Binary metadata**: VERSIONINFO fields (company/product/copyright/...) present as the device brand — no OBS traces
- **Runtime names**: shared-memory section `C920VideoQueue` (`VIRTUALCAM_QUEUE_NAME`), config file `c920-cam.txt` (`VIRTUALCAM_CONFIG_FILE`) — no `OBSVirtualCamVideo` / `obs-virtualcam.txt` artifacts
- **DevicePath**: the filter's registry Instance key gets a USB-format DevicePath (`\\?\usb#vid_046d&pid_0825#<serial>#...`) with a per-machine serial derived from MachineGuid (`VIRTUALCAM_DEVICE_SERIAL` overrides)
- **No PDB files** in release packages
- **CI gate**: `tools/vcam-audit/Audit-VirtualCam.ps1` fails the build on any OBS fingerprint in the package (see its README)

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
   output\lvc920x64.dll
   output\virtualcam-install.bat
   output\virtualcam-uninstall.bat
   ```

### Manual Build (if script fails)

```cmd
cd plugins\win-dshow\virtualcam-module

cmake -B build -S . -G "Visual Studio 17 2022" -A x64 ^
  -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB

cmake --build build --config RelWithDebInfo --parallel
```

Output will be in: `build\RelWithDebInfo\lvc920x64.dll`

## Installation

### Method 1: Replace DLL (Recommended)

1. **Close OBS Studio** if running

2. **Navigate to OBS plugins directory:**
   ```
   C:\Program Files\obs-studio\obs-plugins\win-dshow\
   ```

3. **Backup original DLL:**
   ```cmd
   copy lvc920x64.dll lvc920x64.dll.backup
   ```

4. **Copy custom DLL:**
   ```cmd
   copy path\to\output\lvc920x64.dll .
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
   regsvr32 /s lvc920x64.dll
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
3. Delete `lvc920x64.dll`
4. Rename `lvc920x64.dll.backup` → `lvc920x64.dll`
5. Run OBS as Administrator

### Unregister DLL

```cmd
regsvr32 /u /s lvc920x64.dll
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
- Unregister old DLL: `regsvr32 /u lvc920x64.dll`
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

### Brand Variables (CMakePresets.json)

| Variable | Default | Purpose |
|----------|---------|---------|
| `VIRTUALCAM_BRAND_NAME` | `Logitech HD Pro Webcam C920` | Device name (registry + metadata) |
| `VIRTUALCAM_BRAND_COMPANY` | `Logitech` | VERSIONINFO CompanyName |
| `VIRTUALCAM_LEGAL_COPYRIGHT` | `(C) Logitech. All rights reserved.` | VERSIONINFO LegalCopyright |
| `VIRTUALCAM_COMMENTS` | `HD Pro Webcam C920 driver component` | VERSIONINFO Comments |
| `VIRTUALCAM_QUEUE_NAME` | `C920VideoQueue` | Shared-memory section name |
| `VIRTUALCAM_CONFIG_FILE` | `c920-cam.txt` | Last-resolution config file name |
| `VIRTUALCAM_DEVICE_SERIAL` | *(empty = per-machine)* | DevicePath serial (derived from MachineGuid when empty) |
| `VIRTUALCAM_DEVICE_VIDPID` | `vid_046d&pid_0825` | DevicePath USB VID/PID |

Build a neutral-branded variant by overriding these variables — no source edits required.

### Audit Tool

`tools/vcam-audit/Audit-VirtualCam.ps1` measures how distinguishable the
virtual camera is from a physical webcam (9 detection vectors) and gates
packages in CI against OBS fingerprints. See `tools/vcam-audit/README.md`.

Per-OS audit scripts:

- Windows: `tools/vcam-audit/Audit-VirtualCam.ps1` (requires PowerShell 7:
  `winget install Microsoft.PowerShell`; PS 5.1 is not supported)
- macOS: `tools/vcam-audit-macos/audit-virtualcam.sh` (requires Xcode command
  line tools; run `sudo ./audit-virtualcam.sh`)
- Linux: `tools/vcam-audit-linux/audit-virtualcam.sh` (requires `v4l-utils`)

Every release ships the Windows audit harness inside the package under
`auxdata/vcam-audit/`.

### Runtime identity (Windows)

The camera identity can be changed **without a rebuild**:

- OBS → Virtual Camera configuration dialog → *Virtual Camera Identity*:
  pick a preset (C920 / Brio 500 / Generic UVC / Custom), optionally a serial,
  and **Apply**. OBS launches `vcamctl.exe` elevated (UAC) and re-registers
  the camera.
- CLI: `core\win-dshow\data\vcamctl.exe` with `get`, `set --name N --vid HHHH
  --pid HHHH [--serial S]`, `reset`, `register`, `unregister`.

Overrides are stored under `HKLM\SOFTWARE\Logitech\Identity` (admin-writable
only) and apply at the next registration. The CLSID/GUID intentionally stays
compile-time. Two caveats:

- Conferencing apps that currently hold the camera may lose it until they are
  restarted (the re-register briefly removes the device).
- Verify the result with the audit scan — no rebuild needed, just re-run
  `Audit-VirtualCam.ps1 scan`.

## Cross-platform identity (macOS / Linux)

The same C920 identity story is compiled into the macOS and Linux virtual
cameras; defaults keep stock builds, presets override:

- **macOS** (`VIRTUALCAM_MAC_*`): device name (AVFoundation/CMIO),
  manufacturer, model/serial/UID, plugin file name (`LogiCamera.plugin`
  instead of `obs-mac-virtualcam.plugin`), bundle IDs
  (`com.logitech.webcam.*`), mach service. Both the DAL plugin and the CMIO
  camera extension are rebranded. **Signing caveat:** without a Developer ID
  the camera extension is ad-hoc signed; activating it needs
  `systemextensionsctl developer on` (SIP reduced) — personal use only. The
  ad-hoc team identifier in `codesign -dv` is the documented residual tell.
- **Linux**: OBS loads the forked **vcamuvc** module
  (`plugins/linux-v4l2/v4l2loopback-vcam`, DKMS source deb
  `vcamuvc-dkms_*.deb`). `v4l2-ctl -D` reports driver `uvcvideo`, card
  `HD Pro Webcam C920`, a USB bus_info, discrete C920 sizes at 30 fps.
  Residual tells (documented, not fixable in a userland module):
  `lsmod` shows `vcamuvc`, sysfs exposes a virtual platform device, `lsusb`
  has no entry. If the stock `v4l2loopback` is loaded, OBS prefers
  `vcamuvc` devices; blacklisting the stock module via modprobe.d keeps the
  identity stable.

### Detection vector matrix

| Vector | Windows | macOS | Linux |
|---|---|---|---|
| V1 device name | PASS (registry friendly name) | PASS (AVFoundation name) | PASS (`v4l2-ctl -D` card) |
| V2 CLSID/bundle | PASS (unique GUID) | PASS (bundle IDs) | n/a |
| V3 DevicePath | PASS (USB-format, per-machine serial) | n/a | n/a |
| V4 PnP/sysfs | PASS | n/a | **FAIL (by design)** — virtual platform device, no lsusb |
| V5 metadata/signature | PASS (VERSIONINFO) | **LIMIT** — ad-hoc signature without Developer ID | PASS (driver name `uvcvideo`) |
| V6 classification | PASS | PASS | PASS |
| V7 camera controls | PASS (IAMCameraControl/IAMVideoProcAmp) | n/a | n/a |
| V8 named objects/artifacts | PASS (renamed queue/config) | PASS (DAL file name) | **LIMIT** — discrete sizes OK; module visible |
| V9 support files | PASS (no OBS artifacts) | PASS (no camera-path artifacts) | **LIMIT** — `lsmod`/`dkms` show `vcamuvc` (documented) |

"LIMIT" rows are the honest architecture ceilings described above; the audit
scripts record them instead of hiding them.

### Release pipeline

Tag pushes (`v*`) and manual dispatches build:

- Windows: portable ZIP (`portable_mode` marker + `auxdata/vcam-audit/`) and
  Inno Setup installer (`.exe`)
- macOS: unsigned `.dmg` for Apple Silicon and Intel
- Linux: `.deb`, portable `tar.gz` (with `run-portable.sh`), and the
  `vcamuvc-dkms` module deb

Workflows: `.github/workflows/build-windows.yml` (release owner),
`build-macos.yml`, `build-linux.yml` (upload into the same release).

### Files Modified

1. `CMakePresets.json` - GUID + brand variables for Windows builds
2. `plugins/win-dshow/virtualcam-module/` - camera name, metadata, DevicePath, output name
3. `shared/obs-shared-memory-queue/` - queue/config file names
4. `frontend/updater/updater.cpp` - registers the renamed DLLs after updates
5. `tools/vcam-audit/` - detection audit harness + CI static gate

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
