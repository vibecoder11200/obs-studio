#!/bin/bash
# Build script for OBS Virtual Camera module on Linux using MinGW
# Output: Windows DLL that can be copied to OBS Windows installation

set -e

echo "========================================"
echo "OBS Virtual Camera Linux Build Script"
echo "Target: Logitech HD Pro Webcam C920"
echo "GUID: 76692E1E-F28F-4DD6-9024-C3A999D30EFB"
echo "========================================"
echo

# Check prerequisites
command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || { echo "Error: MinGW not found. Install: sudo apt install mingw-w64"; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo "Error: CMake not found. Install: sudo apt install cmake"; exit 1; }

# Set build paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build-virtualcam-cross"
MODULE_DIR="$SCRIPT_DIR/plugins/win-dshow/virtualcam-module"

# Clean previous build
echo "Cleaning previous build..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo
echo "=== Step 1: Building dependencies ==="

# Build shared-memory-queue
echo "Building shared-memory-queue..."
cmake -B "$BUILD_DIR/obs-shared-memory-queue" \
    -S "$SCRIPT_DIR/shared/obs-shared-memory-queue" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/linux-mingw-w64.cmake" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOS_WINDOWS=ON

cmake --build "$BUILD_DIR/obs-shared-memory-queue" --config RelWithDebInfo

# Build tiny-nv12-scale
echo "Building tiny-nv12-scale..."
cmake -B "$BUILD_DIR/obs-tiny-nv12-scale" \
    -S "$SCRIPT_DIR/shared/obs-tiny-nv12-scale" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/linux-mingw-w64.cmake" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo

cmake --build "$BUILD_DIR/obs-tiny-nv12-scale" --config RelWithDebInfo

# Build libdshowcapture
echo "Building libdshowcapture..."
cmake -B "$BUILD_DIR/libdshowcapture" \
    -S "$SCRIPT_DIR/deps/libdshowcapture" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/linux-mingw-w64.cmake" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DOS_WINDOWS=ON

cmake --build "$BUILD_DIR/libdshowcapture" --config RelWithDebInfo

echo
echo "=== Step 2: Building Virtual Camera module ==="

# Configure virtualcam module
echo "Configuring Virtual Camera module..."
cmake -B "$BUILD_DIR/virtualcam-module" \
    -S "$MODULE_DIR" \
    -DCMAKE_TOOLCHAIN_FILE="$SCRIPT_DIR/cmake/linux-mingw-w64.cmake" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DVIRTUALCAM_GUID=76692E1E-F28F-4DD6-9024-C3A999D30EFB \
    -DOS_WINDOWS=ON

echo
echo "=== Step 3: Compiling ==="
cmake --build "$BUILD_DIR/virtualcam-module" --config RelWithDebInfo -j$(nproc)

echo
echo "=== Step 4: Collecting output files ==="

# Create output directory
OUTPUT_DIR="$SCRIPT_DIR/output-windows"
mkdir -p "$OUTPUT_DIR"

# Copy DLL
if [ -f "$BUILD_DIR/virtualcam-module/obs-virtualcam-module.dll" ]; then
    cp "$BUILD_DIR/virtualcam-module/obs-virtualcam-module.dll" "$OUTPUT_DIR/"
    echo "✓ DLL copied to: $OUTPUT_DIR/obs-virtualcam-module.dll"
else
    echo "Warning: DLL not found at expected location"
    find "$BUILD_DIR" -name "*.dll" -o -name "*.so" | head -10
fi

echo
echo "========================================"
echo "BUILD COMPLETE!"
echo "========================================"
echo
echo "Output files:"
ls -lh "$OUTPUT_DIR/"
echo
echo "Next steps:"
echo "1. Copy output-windows/obs-virtualcam-module.dll to Windows machine"
echo "2. Navigate to: C:\\Program Files\\obs-studio\\obs-plugins\\win-dshow\\"
echo "3. Backup original obs-virtualcam-module.dll"
echo "4. Replace with new DLL"
echo "5. Run OBS as Administrator"
echo "6. Start Virtual Camera"
echo "7. Check Device Manager - should show 'Logitech HD Pro Webcam C920'"
echo
