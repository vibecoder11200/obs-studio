#!/usr/bin/env bash
# Assembles vcamuvc-dkms_<version>_all.deb from the vendored module source
# (plugins/linux-v4l2/v4l2loopback-vcam). Uses dpkg-deb directly - no
# debhelper needed in CI.
#
# usage: build-dkms-deb.sh <output-dir> [version]
#   output-dir  where the .deb is written
#   version     package version (default: derived from git describe)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_DIR="$SCRIPT_DIR/../../../plugins/linux-v4l2/v4l2loopback-vcam"
OUTPUT_DIR="${1:?usage: build-dkms-deb.sh <output-dir> [version]}"
VERSION="${2:-$(git -C "$SCRIPT_DIR/../../.." describe --tags --always || echo 0.0.0)}"
# dpkg rejects versions that do not start with a digit; v-prefixed tags
# (the only tags this workflow builds) must lose the prefix.
VERSION="${VERSION#v}"
# keep the dkms module version free of a debian revision suffix
MODULE_VERSION="${VERSION%%-*}"

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

if [ ! -f "$MODULE_DIR/v4l2loopback.c" ] || [ ! -f "$MODULE_DIR/dkms.conf" ]; then
	echo "module source not found under $MODULE_DIR" >&2
	exit 2
fi

DEBIAN="$STAGING/DEBIAN"
mkdir -p "$DEBIAN" "$STAGING/usr/src/vcamuvc-$MODULE_VERSION"

install -m 0644 \
	"$MODULE_DIR/v4l2loopback.c" \
	"$MODULE_DIR/v4l2loopback.h" \
	"$MODULE_DIR/v4l2loopback_formats.h" \
	"$MODULE_DIR/Kbuild" \
	"$MODULE_DIR/Makefile" \
	"$MODULE_DIR/dkms.conf" \
	"$MODULE_DIR/README-provenance.md" \
	"$MODULE_DIR/COPYING" \
	"$STAGING/usr/src/vcamuvc-$MODULE_VERSION/"

sed -e "s/VERSION_TOKEN/$VERSION/" "$SCRIPT_DIR/control" >"$DEBIAN/control"
INSTALLED_SIZE="$(du -sk "$STAGING" | cut -f1)"
sed -i -e "s/INSTALLED_SIZE_TOKEN/$INSTALLED_SIZE/" "$DEBIAN/control"

install -m 0755 "$SCRIPT_DIR/postinst" "$DEBIAN/postinst"
install -m 0755 "$SCRIPT_DIR/prerm" "$DEBIAN/prerm"

# keep dkms.conf's PACKAGE_VERSION in sync with the installed tree version
# (postinst derives it from the /usr/src/vcamuvc-<version> directory name)
sed -i -e "s/^PACKAGE_VERSION=.*/PACKAGE_VERSION=\"$MODULE_VERSION\"/" \
	"$STAGING/usr/src/vcamuvc-$MODULE_VERSION/dkms.conf"

# mktemp creates the staging root 0700; ship standard directory perms
chmod 0755 "$STAGING" "$STAGING/usr" "$STAGING/usr/src" "$STAGING/usr/src/vcamuvc-$MODULE_VERSION" "$DEBIAN"

mkdir -p "$OUTPUT_DIR"
OUTPUT="$OUTPUT_DIR/vcamuvc-dkms_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGING" "$OUTPUT"
echo "built $OUTPUT"
