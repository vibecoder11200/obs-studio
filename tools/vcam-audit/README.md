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
`FAIL` (distinguishing evidence found). The audit evaluates the *fork's own
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

## CI wiring

See `.github/workflows/build-windows.yml` ("Antidetect Audit" step): runs
`static` on the packaged zip immediately after packaging and fails the job on
violations. The "VirtualCam Smoke Test" step additionally registers the DLL on
the runner and enumerates it via COM (dynamic V1/V2/V3/V5 checks).

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
