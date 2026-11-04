# vcamuvc — forked v4l2loopback (identity patch)

Vendored fork of [v4l2loopback](https://github.com/umlaeute/v4l2loopback),
**upstream commit `442d720262e150084e7923068fb3c01acc42a253` (master,
post-v0.15.4; pinned for the kernel-6.18 `v4l2_fh_*` compat layer)**,
carrying a small identity patch so the virtual camera reads like a real USB
webcam (HD Pro Webcam C920) at every userland layer a driver name can reach.
Verified to build against the 6.18.x header set (`modinfo` reports
`name: vcamuvc`, `description: USB Video Class driver`).

## License

GPL-2.0 (see `COPYING`, kept verbatim from upstream). This vendored copy
inherits upstream licensing in full.

## What the identity patch changes (and why)

| Surface | Upstream | Fork |
|---|---|---|
| `v4l2_capability.driver` (`v4l2-ctl -D`) | `v4l2 loopback` | `uvcvideo` |
| `v4l2_capability.bus_info` | `platform:v4l2loopback-NNN` | `usb-0000:00:14.0-N` |
| default card label | `Dummy video device (0x…)` | `HD Pro Webcam C920` (still overridable via the `card_label` parameter, which OBS sets from `VIRTUALCAM_LINUX_CARD_LABEL`) |
| `v4l2_dev.name` | `v4l2loopback-NNN` | `uvcvideo-NNN` |
| `/dev` control node | `/dev/v4l2loopback` | `/dev/vcamuvc` |
| input/output names (`VIDIOC_ENUMINPUT`) | `loopback` / `loopback in` | `Camera 1` |
| framesizes | continuous range up to 8192x8192 | discrete 1920x1080 / 1280x720 / 640x480 |
| frame intervals | continuous 1/1000 … | discrete 30 fps |
| `modinfo` description | `V4L2 loopback video device` | `USB Video Class driver` (matches real `uvcvideo`) |
| debug/init messages (dmesg) | `v4l2-loopback[…]` | `uvcvideo: …` |
| module name / `lsmod` | `v4l2loopback` | `vcamuvc` |

Internal C symbol names (`v4l2_loopback_add`, …) keep upstream naming. Note
the patch does rename upstream's `ID_V4L2LOOPBACK_CAPABILITIES` uevent tag to
`ID_VCAM_CAPABILITIES` (a literal `v4l2loopback` string readable from
userland via the udev database would be a free win for any scanner).

Untouched on purpose: the `exclusive_caps` logic (Chrome/Zoom need it), the
buffer/scheduling machinery, and all of upstream's module parameters.

## Residual tells (documented, by design)

These remain and are NOT fixable in a userland-loadable module without
crossing into rootkit territory (module hiding is an explicit non-goal):

- `lsmod` / `modinfo` show the module name `vcamuvc` with upstream's parameter
  set (`max_buffers`, `exclusive_caps`, …) — a real UVC camera has no module.
- the module's symbol table keeps the upstream C symbol names
  (`v4l2loopback_*`, `v4l2_loopback_*`); the `.ko` file is world-readable
  wherever it is installed (`/usr/src/vcamuvc-*` via dkms,
  `/lib/modules/<kernel>/extra`), so those strings can be found without root
  (unlike `/proc/kallsyms`, which is root-only).
- sysfs exposes the platform device path
  (`/sys/devices/virtual/video*/`) instead of a USB device; there is no
  `lsusb` entry.
- `tools/vcam-audit-linux/audit-virtualcam.sh` records exactly which of these
  remain on the running system.

## Maintenance

The vendored copy is pinned per release; refreshing it is a scheduled task:
copy the new upstream `v4l2loopback.{c,h}` + `v4l2loopback_formats.h`, re-apply
the patch (every replacement above asserts exactly one match), and update the
upstream commit recorded here.
