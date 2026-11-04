#!/usr/bin/env bash
# Linux virtual camera identity audit.
#
# Emits the same vector/verdict JSON shape as the Windows/macOS scans:
#   V1 - device card label + driver name per /dev/videoN (v4l2-ctl -D)
#   V4 - sysfs backing device (architecture limit: expected FAIL, recorded)
#   V8 - framesizes/frameintervals per device (discrete C920 set expected)
#   V9 - residual tells: lsmod / dkms status (documented, not fixable)
#
# Usage: ./audit-virtualcam.sh [--output FILE]
#
# Requires: v4l2-ctl (v4l-utils). Without it the report degrades to WARN rows.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BLOCKLIST="$SCRIPT_DIR/blocklist.json"
OUTPUT_FILE=""

while [ $# -gt 0 ]; do
	case "$1" in
	--output)
		OUTPUT_FILE="$2"
		shift 2
		;;
	*)
		echo "usage: $0 [--output FILE]" >&2
		exit 2
		;;
	esac
done

if [ ! -f "$BLOCKLIST" ]; then
	echo "blocklist not found: $BLOCKLIST" >&2
	exit 2
fi

ROWS_FILE="$(mktemp)"
trap 'rm -f "$ROWS_FILE"' EXIT

# ----------------------------------------------------------------- helpers

json_escape() {
	local s="$1"
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/ /}
	s=${s//$'\t'/ }
	printf '%s' "$s"
}

contains() {
	printf '%s' "$1" | grep -qiF -- "$2"
}

pattern_product() {
	/usr/bin/python3 - "$BLOCKLIST" "$1" <<'PY'
import json, sys
bl = json.load(open(sys.argv[1]))
for e in bl[sys.argv[2]]:
    print(f"{e['pattern']}\t{e['product']}")
PY
}

add_row() {
	printf '{"vector": "%s", "device": "%s", "value": "%s", "verdict": "%s", "reason": "%s"}\n' \
		"$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$4")" "$(json_escape "$5")" >>"$ROWS_FILE"
}

# ----------------------------------------------------------------- probes

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
KERNEL_RELEASE="$(uname -r)"

if command -v v4l2-ctl >/dev/null 2>&1; then
	VIDEO_DEVICES="$(ls -1 /dev/video* 2>/dev/null | sed '/^$/d')"
	V4L2_CTL_PRESENT=1
else
	VIDEO_DEVICES=""
	V4L2_CTL_PRESENT=0
fi

LSMOD_MATCH="$(lsmod 2>/dev/null | grep -E "v4l2loopback|vcamuvc" || true)"
DKMS_STATUS="$(dkms status 2>/dev/null | grep -i vcamuvc || true)"

# ----------------------------------------------------------------- vectors

if [ "$V4L2_CTL_PRESENT" -eq 0 ]; then
	add_row "V1" "<probe>" "v4l2-ctl not found" "WARN" \
		"v4l-utils not installed; install v4l-utils to run the identity probe"
else
	for dev in $VIDEO_DEVICES; do
		INFO="$(v4l2-ctl -d "$dev" -D 2>/dev/null || true)"
		[ -n "$INFO" ] || continue

		DRIVER="$(printf '%s\n' "$INFO" | sed -n 's/^[[:space:]]*Driver name[[:space:]]*:[[:space:]]*//p' | head -n 1)"
		CARD="$(printf '%s\n' "$INFO" | sed -n 's/^[[:space:]]*Card type[[:space:]]*:[[:space:]]*//p' | head -n 1)"
		BUS_INFO="$(printf '%s\n' "$INFO" | sed -n 's/^[[:space:]]*Bus info[[:space:]]*:[[:space:]]*//p' | head -n 1)"
		VALUE="driver=$(json_escape "$DRIVER") card=$(json_escape "$CARD") bus=$(json_escape "$BUS_INFO")"

		V1_VERDICT="PASS"
		V1_REASON="driver name and card label carry no virtual-camera fingerprint"
		while IFS=$'\t' read -r pattern product; do
			[ -n "$pattern" ] || continue
			if contains "$DRIVER" "$pattern" && [ "$pattern" != "uvcvideo" ]; then
				V1_VERDICT="FAIL"
				V1_REASON="driver name matches '$pattern' ($product)"
				break
			fi
			if contains "$CARD" "$pattern"; then
				V1_VERDICT="FAIL"
				V1_REASON="card label matches '$pattern' ($product)"
				break
			fi
		done < <(pattern_product name_patterns)
		# driver_names section: only the stock-loopback entry is a FAIL;
		# 'uvcvideo' is the GOOD identity, so it is excluded above
		while IFS=$'\t' read -r pattern product; do
			[ -n "$pattern" ] || continue
			[ "$pattern" = "uvcvideo" ] && continue
			if [ "$V1_VERDICT" != "FAIL" ] && contains "$DRIVER" "$pattern"; then
				V1_VERDICT="FAIL"
				V1_REASON="driver name matches '$pattern' ($product)"
				break
			fi
		done < <(pattern_product driver_names)

		add_row "V1" "$dev" "$VALUE" "$V1_VERDICT" "$V1_REASON"

		# V4: sysfs backing device - architecture limit, recorded honestly
		SYSFS_DEVICE="$(readlink -f "/sys/class/video4linux/$(basename "$dev")/device" 2>/dev/null || true)"
		V4_VERDICT="PASS"
		V4_REASON="sysfs backing device looks like a real bus attachment"
		if printf '%s' "$SYSFS_DEVICE" | grep -q "/devices/virtual/"; then
			V4_VERDICT="FAIL"
			V4_REASON="documented architecture limit: a loopback module cannot fake the USB sysfs tree (no lsusb entry either)"
		elif [ -z "$SYSFS_DEVICE" ]; then
			V4_VERDICT="WARN"
			V4_REASON="sysfs device path unavailable"
		fi
		add_row "V4" "$dev" "$(json_escape "$SYSFS_DEVICE")" "$V4_VERDICT" "$V4_REASON"

		# V8: framesizes + frameintervals (discrete C920 set expected).
		# v4l2-ctl prints `Size: Discrete WxH` (or legacy `[N]: WxH`) —
		# match both, the `[N]: ` lines alone never appear for framesizes.
		SIZES="$(v4l2-ctl -d "$dev" --list-framesizes=MJPG 2>/dev/null | sed -n -E 's/^\[[[:space:]]*[0-9]+\]:[[:space:]]*//p; s/^Size: Discrete[[:space:]]+//p' | sort -u | tr '\n' ';')"
		IVALS="$(v4l2-ctl -d "$dev" --list-frameintervals=width=1920,height=1080,pixelformat=MJPG 2>/dev/null | sed -n -E 's/^\[[[:space:]]*[0-9]+\]:[[:space:]]*//p; s/^Interval: Discrete[[:space:]]+//p' | sort -u | tr '\n' ';')"
		V8_VERDICT="WARN"
		V8_REASON="framesize/interval reporting unavailable"
		if printf '%s' "$SIZES" | grep -q "1920x1080" && printf '%s' "$SIZES" | grep -q "1280x720" && printf '%s' "$SIZES" | grep -q "640x480"; then
			if printf '%s' "$SIZES" | grep -q "STEPWISE\|Continuous"; then
				V8_VERDICT="WARN"
				V8_REASON="C920 sizes present but reported as a continuous range (stock-module behavior)"
			elif [ -z "$IVALS" ] || printf '%s' "$IVALS" | grep -q "STEPWISE\|Continuous"; then
				V8_VERDICT="WARN"
				V8_REASON="C920 sizes discrete but frame intervals not discrete"
			elif printf '%s' "$IVALS" | grep -Eq '30\.000 fps|0\.033s'; then
				V8_VERDICT="PASS"
				V8_REASON="discrete C920-matched sizes and 30 fps interval"
			else
				V8_VERDICT="WARN"
				V8_REASON="C920 sizes discrete but interval set does not contain 30 fps"
			fi
		fi
		add_row "V8" "$dev" "sizes=$SIZES intervals=$IVALS" "$V8_VERDICT" "$V8_REASON"
	done
fi

# V9: residual tells - which module backs the devices right now.
V9_VALUE="lsmod: $(printf '%s' "$LSMOD_MATCH" | tr '\n' ';')"
[ -n "$DKMS_STATUS" ] && V9_VALUE="$V9_VALUE dkms: $DKMS_STATUS"
V9_VERDICT="PASS"
V9_REASON="no loopback module loaded; nothing to flag"
if contains "$LSMOD_MATCH" "v4l2loopback"; then
	V9_VERDICT="FAIL"
	V9_REASON="stock v4l2loopback is loaded - the identity reverted to the stock tell (blacklist it or load vcamuvc)"
elif contains "$LSMOD_MATCH" "vcamuvc"; then
	V9_VERDICT="WARN"
	V9_REASON="documented residual: the forked module itself is visible in lsmod (module hiding is out of scope)"
fi
add_row "V9" "<residual-tells>" "$V9_VALUE" "$V9_VERDICT" "$V9_REASON"

# ----------------------------------------------------------------- report

VECTORS="$(awk 'NR > 1 {printf ",\n    "} {printf "%s", $0}' "$ROWS_FILE")"

REPORT="{
  \"scanned_at\": \"$TIMESTAMP\",
  \"host\": { \"os\": \"Linux\", \"kernel\": \"$KERNEL_RELEASE\" },
  \"loopback_module\": {
    \"lsmod\": \"$(json_escape "$LSMOD_MATCH")\",
    \"dkms\": \"$(json_escape "$DKMS_STATUS")\"
  },
  \"vectors\": [
    $VECTORS
  ]
}
"

if [ -n "$OUTPUT_FILE" ]; then
	printf '%s' "$REPORT" >"$OUTPUT_FILE"
	echo "report written to $OUTPUT_FILE"
else
	printf '%s' "$REPORT"
fi
