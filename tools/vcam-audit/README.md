# vcam-audit — Virtual Camera Detection Audit Harness

Measures how distinguishable a virtual camera is from a physical webcam across
nine detection vectors (V1–V9), and gates build packages in CI against OBS
fingerprints. Read-only: it never writes the registry, files, or device state.

## Requirements

- PowerShell 7 (`pwsh`) — Windows 10/11 for `scan`/`diff`; any OS for `static`.
- Optional: a physical webcam as the baseline reference.

## Detection vectors

| # | Vector | Source |
|---|--------|--------|
| V1 | Friendly name / substring blocklist | DShow moniker property bag |
| V2 | Known CLSID blocklist | moniker display name |
| V3 | `DevicePath` string (moniker + registry Instance key) | property bag, `HKCR\CLSID\{category}\Instance` |
| V4 | PnP devnode / Device Manager visibility | `Get-PnpDevice`, KSCATEGORY DeviceClasses |
| V5 | DLL metadata (VERSIONINFO, file name) | `InprocServer32` target |
| V6 | System-camera presence and HW/SW classification | KSCATEGORY_VIDEO/CAPTURE DeviceClasses |
| V7 | Camera controls (`IAMCameraControl`/`IAMVideoProcAmp`) | COM query on the filter — best effort |
| V8 | Named kernel objects (`OpenFileMappingW` probes) | blocklist `named_sections` |
| V9 | Config-dir artifacts (`obs-virtualcam.txt`…) | blocklist `config_artifacts` |

Verdicts: `PASS` (indistinguishable at this vector), `WARN` (present but odd),
`FAIL` (distinguishing evidence found). V3 additionally carries a
**serial-format coherence check**: when the DevicePath's VID/PID pair is one of
the identities below, the serial segment must match that hardware's real serial
format — a mismatch is a `WARN` (never `FAIL`; the location-ID form is itself
Windows-generated) naming the expected format. The audit evaluates the *fork's own
virtual camera* against the same blocklist an external detector would use —
old names (`OBSVirtualCamVideo`, `obs-virtualcam.txt`, the upstream OBS CLSID)
are in the blocklist on purpose so regressions fail loudly.

## Usage

```powershell
# Full scan of the machine (virtual cam + physical cams), JSON report:
./Audit-VirtualCam.ps1 scan -Json -OutFile scan-after.json

# Same, human-readable table:
./Audit-VirtualCam.ps1 scan

# Diff the live virtual camera (CLSID defaults to the fork GUID) against a
# baseline scan captured with a physical webcam:
./Audit-VirtualCam.ps1 diff -Baseline real-webcam.json -Json

# Canonical static gate on a build package (CI uses this; exit 0 = pass):
./Audit-VirtualCam.ps1 static -Package build_x64/obs-studio-33.0.1-windows-x64.zip
./Audit-VirtualCam.ps1 static -Package <zip> -Json -OutFile static-report.json
```

### Baseline capture (real webcam)

On a machine with a physical webcam run `scan -Json -OutFile real-webcam.json`
**before** installing the virtual camera (or on a profile/machine without it).
`diff` joins the live scan to the baseline **by CLSID** — never by friendly
name, because the fork deliberately names the virtual camera after the real
one, which would make a name join ambiguous (the tool hard-fails on any
ambiguous join instead of guessing).

For full V8 coverage (`OpenFileMappingW` probes), keep the virtual camera
output **active** in OBS while scanning: the shared-memory section only exists
while OBS streams.

## Canonical static gate (normative — phases 2 and 5 reference this verbatim)

`static` is the CI gate for the "antidetect" package:

1. The virtualcam DLL is located in the zip **by its CLSID resource**
   (GUID `76692E1E-F28F-4DD6-9024-C3A999D30EFB` byte pattern), never by file
   name — renaming the DLL cannot dodge the gate.
2. Scanned: VERSIONINFO string fields (`CompanyName`, `FileDescription`,
   `ProductName`, `Comments`, `LegalCopyright`, `InternalName`,
   `OriginalFilename`), the DLL file name, embedded UTF-8 and UTF-16 strings,
   and every zip entry name.
3. Patterns (case-insensitive): `OBS Virtual`, `obs-virtualcam`,
   `OBSVirtualCam`, `OBS Project`, `obs-studio`.
4. Allowlist (`blocklist.json` → `static_gate.allowlist`): `obs64.exe` /
   `obs32.exe` — the filter's self-detection that hides it from OBS's own
   capture source list; documented per red-team adjudication.
5. Out of scope: PDB symbols (PDBs are excluded from packages separately —
   CI asserts no `*.pdb` entry at all).
6. Gate must fail **closed**: if the CLSID-located DLL cannot be found, the
   gate exits non-zero.

Do not narrow this gate as a "mitigation"; any scope change requires re-running
the baseline diff against a real webcam per the plan.

## Shipped in every release

The packaging step copies this directory (script, blocklist, vectors, README —
no samples) into the package under `auxdata/vcam-audit/`, so users can verify
the camera identity without leaving the release. It still requires PowerShell
7 (`winget install Microsoft.PowerShell`); PS 5.1 compatibility is explicitly
out of scope.

## Runtime identity helper

`vcamctl.exe` (shipped next to the camera DLLs under `core\win-dshow\data\`)
changes the identity at runtime: `get` prints what the next registration will
apply, `set --name N --vid HHHH --pid HHHH [--serial S | --generate]` writes
the override under `HKLM\SOFTWARE\Logitech\Identity` (admin-writable only)
and re-registers, `reset` returns to the build defaults (the next registration
generates a fresh random serial — reset = replaced camera unit). After any change, re-run
this scan — no rebuild is needed. The presets offered in the OBS dialog use
the same mechanism; `check-preset-coherence.ps1` (CI) guarantees they never
collide with this blocklist.

## CI wiring

See `.github/workflows/build-windows.yml` ("Antidetect Audit" step): runs the
preset-coherence check (now also the dialog↔serial_formats sync) and `static`
on the packaged zip immediately after packaging and fails the job on
violations. The "VirtualCam Smoke Test" step additionally registers the DLL on
the runner, enumerates it via COM (dynamic V1/V2/V3/V5 checks), asserts the
registered serial's format, and round-trips one `vcamctl set --generate` per
format class. The per-OS siblings are
`tools/vcam-audit-macos/audit-virtualcam.sh` and
`tools/vcam-audit-linux/audit-virtualcam.sh` (same vector/verdict JSON shape).

## Serial formats

The camera presets ship with per-vendor serial formats matching real hardware,
verified against descriptor dumps and the linuxhw/LsUSB dataset:

| VID:PID | Camera | Serial format | Real example |
|---|---|---|---|
| 046d:082d | Logitech HD Pro Webcam C920 | 8HEX | `E1CA2A7F` |
| 046d:085c | Logitech C922 Pro Stream | 8HEX | — |
| 046d:0843 | Logitech Webcam C930e | 8HEX | `CAC79E4E` |
| 046d:085e | Logitech BRIO Ultra HD | 8DIGIT | `93004248` |
| 046d:0943 | Logitech Brio 500 | 12ALNUM | `2419LZ50AFL8` |
| 0fd9:0078 | Elgato Facecam | ELGATO | `FW15K1A12513` |
| 04f2:b76f | ACER HD User Facing | LOCATION | `6&330c68f9&0&0000` |
| 0408:5365 | HP TrueVision HD Camera | LOCATION | — |
| 5986:0652 | Lenovo EasyCamera | LOCATION | — |
| 0c45:6723 | Integrated_Webcam_HD | LOCATION | — |
| 13d3:56a2 | USB2.0 HD UVC WebCam | LOCATION | — |
| 0408:1110 | HD Camera (Quanta) | LOCATION | — |

LOCATION identities carry `&mi_00` in the DevicePath (composite UVC layout)
and use the Windows-generated `6&xxxxxxxx&0&0000` location ID as the serial,
because these cameras expose no real serial number. A legacy `046d:0825` row
(the old dialog's wrong C270 PID) is kept so pre-migration installs still
audit cleanly; the module migrates such installs to `082d` at registration.

The same table exists in `plugins/win-dshow/virtualcam-module/virtualcam-serial.h`
(the generator) and in the OBS dialog presets. `check-preset-coherence.ps1`
(CI) cross-checks the dialog rows against the `serial_formats` array in
`blocklist.json` so the three cannot drift apart.

## Samples

`samples/` holds scan JSON reports captured from a real machine (Windows 11
26300, laptop with a physical "ACER HD User Facing" camera; host name and user
paths sanitized):

- `scan-real-webcam.json` — baseline captured with only the physical camera
  installed (reference for `diff`).
- `scan-virtualcam.json` — the same machine with the fork's virtual camera
  (`33.0.1-c920.2-beta.1`) installed and registered.
- `diff-virtualcam-vs-real.json` — the `diff` report joining the two: the
  virtual camera passes V1/V2/V3/V5/V8/V9 and structurally cannot pass V4/V6
  (no PnP devnode / system camera interface — user-mode DShow limit; kernel
  driver or Frame Server territory).
- `scan-virtualcam-live.json` — captured **while the virtual camera output was
  streaming** (OBS `--startvirtualcam`, probe run in the interactive session —
  session-0 probes cannot see session-local named objects). Shows the rebrand
  working end to end: `OBSVirtualCamVideo`/`OBSVirtualCamVideo4K` absent while
  `C920VideoQueue` is OPEN, so V8 only trips once the scanner knows the new
  queue name (added to `blocklist.json` after this run); V1/V2/V3/V5/V9 stay
  PASS while live.
