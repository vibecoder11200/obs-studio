#!/usr/bin/env bash
# macOS virtual camera identity audit.
#
# Verifies what an AVFoundation / CMIO client would observe about the virtual
# camera and emits the same vector/verdict JSON shape as the Windows scan
# (tools/vcam-audit/Audit-VirtualCam.ps1):
#   V1 - device names (AVFoundation + system_profiler) vs blocklist patterns
#   V2 - camera-extension bundle ids (pluginkit) vs blocklist bundle ids
#   V5 - codesign metadata of the installed DAL plugin / extension
#   V8 - installed DAL plugin files (/Library/CoreMediaIO/Plug-Ins/DAL)
#   V9 - support files (OBS preferences, extension registrations)
#
# Usage: ./audit-virtualcam.sh [--output FILE]
#   --output FILE  write the JSON report to FILE (default: stdout)
#
# Requires: macOS with Xcode command line tools (the AVFoundation probe runs
# `swift list-cameras.swift` from this directory).

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

# json_escape "text" - minimal string escaping for the report
json_escape() {
	local s="$1"
	s=${s//\\/\\\\}
	s=${s//\"/\\\"}
	s=${s//$'\n'/ /}
	s=${s//$'\t'/ }
	printf '%s' "$s"
}

# json_escape_line - escape JSON specials in raw probe output for the
# top-level report arrays, while keeping the tab/newline structure the
# assembler below splits on (add_row/json_escape already cover the rows)
json_escape_line() {
	sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# contains haystack needle - fixed-string case-insensitive containment
# (grep -iF keeps this compatible with the stock macOS bash 3.2)
contains() {
	printf '%s' "$1" | grep -qiF -- "$2"
}

# pattern_product BLOCKLIST-SECTION - emits "pattern<TAB>product" lines
pattern_product() {
	/usr/bin/python3 - "$BLOCKLIST" "$1" <<'PY'
import json, sys
bl = json.load(open(sys.argv[1]))
for e in bl[sys.argv[2]]:
    print(f"{e['pattern']}\t{e['product']}")
PY
}

# add_row "vector" "device" "value" "verdict" "reason"
add_row() {
	printf '{"vector": "%s", "device": "%s", "value": "%s", "verdict": "%s", "reason": "%s"}\n' \
		"$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$4")" "$(json_escape "$5")" >>"$ROWS_FILE"
}

# scan_name "device" "value" - V1-style row against the name patterns
scan_name() {
	local device="$1" value="$2" pattern product
	while IFS=$'\t' read -r pattern product; do
		[ -n "$pattern" ] || continue
		if contains "$value" "$pattern"; then
			add_row "V1" "$device" "$value" "FAIL" "name matches blocklist pattern '$pattern' ($product)"
			return
		fi
	done < <(pattern_product name_patterns)
	add_row "V1" "$device" "$value" "PASS" "name carries no known virtual-camera fingerprint"
}

# ----------------------------------------------------------------- probes

TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
MACOS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"

# V1: AVFoundation device names (the surface conferencing apps read).
AV_DEVICES=""
if command -v swift >/dev/null 2>&1; then
	AV_DEVICES="$(cd "$SCRIPT_DIR" && swift list-cameras.swift 2>/dev/null || echo "<swift-probe-failed>")"
else
	AV_DEVICES="<swift-not-installed>"
fi

# V1 supplemental: system_profiler camera listing.
SYSTEM_PROFILER_CAMERAS="$(system_profiler SPCameraDataType 2>/dev/null | sed -n 's/^[[:space:]]*\([^:]*\):$/\1/p' | sed '/^$/d')"

# V2: registered camera extensions.
PLUGINKIT_OUTPUT="$(pluginkit -m -p com.apple.cmio.CameraExtension 2>/dev/null | sed '/^$/d')"

# V5/V8: installed DAL plugins.
DAL_DIR="/Library/CoreMediaIO/Plug-Ins/DAL"
DAL_FILES=""
if [ -d "$DAL_DIR" ]; then
	DAL_FILES="$(ls -1 "$DAL_DIR" 2>/dev/null | sed '/^$/d')"
fi

# V5: codesign metadata for the first DAL bundle, if any.
CODESIGN_OUTPUT="not-probed"
FIRST_DAL=""
if [ -n "$DAL_FILES" ]; then
	FIRST_DAL="$(printf '%s\n' "$DAL_FILES" | head -n 1)"
	CODESIGN_OUTPUT="$(codesign -dv "$DAL_DIR/$FIRST_DAL" 2>&1 | sed '/^$/d' || true)"
fi

# V9: OBS support artifacts visible system-wide.
V9_VALUE=""
[ -n "$PLUGINKIT_OUTPUT" ] && V9_VALUE="camera-extensions: $PLUGINKIT_OUTPUT"
if ls "$HOME/Library/Preferences/com.obsproject."* >/dev/null 2>&1; then
	V9_VALUE="$V9_VALUE obs-preferences-present"
fi

# ----------------------------------------------------------------- vectors

# V1 rows: every AVFoundation device name.
case "$AV_DEVICES" in
"<swift-probe-failed>" | "<swift-not-installed>")
	add_row "V1" "<avfoundation-probe>" "$AV_DEVICES" "WARN" \
		"AVFoundation device enumeration did not run (needs Xcode command line tools)"
	;;
*)
	while IFS=$'\t' read -r name uid model; do
		[ -n "$name" ] || continue
		scan_name "$name" "$name"
	done <<<"$AV_DEVICES"
	;;
esac

# V2 row: registered camera extensions vs blocklist bundle ids.
V2_VALUE="$(printf '%s' "$PLUGINKIT_OUTPUT" | tr '\n' ';')"
V2_VERDICT="PASS"
V2_REASON="no camera-extension bundle id matches the blocklist"
if [ -z "$PLUGINKIT_OUTPUT" ]; then
	V2_VERDICT="WARN"
	V2_REASON="no camera extensions registered"
else
	while IFS=$'\t' read -r pattern product; do
		[ -n "$pattern" ] || continue
		if contains "$V2_VALUE" "$pattern"; then
			V2_VERDICT="FAIL"
			V2_REASON="registered extension bundle id matches '$pattern' ($product)"
			break
		fi
	done < <(pattern_product bundle_ids)
fi
add_row "V2" "<camera-extensions>" "$V2_VALUE" "$V2_VERDICT" "$V2_REASON"

# V5 row: codesign metadata of the installed DAL bundle.
V5_VERDICT="WARN"
V5_REASON="no DAL plugin installed (modern macOS uses the camera extension)"
if [ -n "$FIRST_DAL" ]; then
	if printf '%s' "$CODESIGN_OUTPUT" | grep -q "linker-signed\|Signature=adhoc"; then
		V5_VERDICT="WARN"
		V5_REASON="ad-hoc signature (unsigned fork build); the team identifier is the documented residual tell"
	elif printf '%s' "$CODESIGN_OUTPUT" | grep -q "Authority=\|TeamIdentifier="; then
		V5_VERDICT="PASS"
		V5_REASON="identified signature present"
	else
		V5_VERDICT="WARN"
		V5_REASON="signature metadata unavailable"
	fi
fi
add_row "V5" "${FIRST_DAL:-<none>}" "$CODESIGN_OUTPUT" "$V5_VERDICT" "$V5_REASON"

# V8 rows: installed DAL plugin file names.
if [ -n "$DAL_FILES" ]; then
	while IFS= read -r dal_file; do
		[ -n "$dal_file" ] || continue
		V8_VERDICT="PASS"
		V8_REASON="installed DAL plugin file name carries no known fingerprint"
		while IFS=$'\t' read -r pattern product; do
			[ -n "$pattern" ] || continue
			if contains "$dal_file" "$pattern"; then
				V8_VERDICT="FAIL"
				V8_REASON="installed file name matches '$pattern' ($product)"
				break
			fi
		done < <(pattern_product file_patterns)
		add_row "V8" "$dal_file" "$DAL_DIR/$dal_file" "$V8_VERDICT" "$V8_REASON"
	done <<<"$DAL_FILES"
else
	add_row "V8" "<none>" "$DAL_DIR" "WARN" \
		"DAL plugin directory missing or empty (camera extension path is the active one)"
fi

# V9 row: OBS support artifacts.
V9_VERDICT="PASS"
V9_REASON="no OBS-specific support artifacts on the camera path"
if contains "$V9_VALUE" "obsproject"; then
	V9_VERDICT="WARN"
	V9_REASON="OBS Studio itself is installed (app artifacts exist; not a camera-identity failure)"
fi
add_row "V9" "<support-files>" "$V9_VALUE" "$V9_VERDICT" "$V9_REASON"

# ----------------------------------------------------------------- report

VECTORS="$(awk 'NR > 1 {printf ",\n    "} {printf "%s", $0}' "$ROWS_FILE")"

REPORT="{
  \"scanned_at\": \"$TIMESTAMP\",
  \"host\": { \"os\": \"macOS\", \"version\": \"$MACOS_VERSION\" },
  \"avfoundation_devices\": [
$(printf '%s\n' "$AV_DEVICES" | json_escape_line | awk -F'\t' 'NF { printf "    { \"name\": \"%s\", \"unique_id\": \"%s\", \"model_id\": \"%s\" },\n", $1, $2, $3 }' | sed '$ s/,$//')
  ],
  \"system_profiler_cameras\": [
$(printf '%s\n' "$SYSTEM_PROFILER_CAMERAS" | sed '/^$/d' | json_escape_line | awk '{ printf "    \"%s\",", $0 }' | sed '$ s/,$//')
  ],
  \"cmio_extensions\": [
$(printf '%s\n' "$PLUGINKIT_OUTPUT" | sed '/^$/d' | json_escape_line | awk '{ printf "    \"%s\",", $0 }' | sed '$ s/,$//')
  ],
  \"dal_plugins\": [
$(printf '%s\n' "$DAL_FILES" | sed '/^$/d' | json_escape_line | awk -v d="$DAL_DIR" '{ printf "    \"%s/%s\",", d, $0 }' | sed '$ s/,$//')
  ],
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
