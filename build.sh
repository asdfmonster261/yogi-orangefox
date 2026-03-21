#!/bin/bash
#
# build.sh — OrangeFox Recovery build script for all Tensor Pixel devices.
#
# Usage:
#   ./build.sh [--family gs201|zuma|zumapro|gs101] [--notrm] [-j N] [--name TAG]
#
# Options:
#   --family FAMILY   Set SoC family before lunch (gs201/zuma/zumapro/gs101).
#                     If omitted, vendorsetup.sh interactive menu is used.
#   --notrm           Don't clean out/target/product/pixels before build.
#   -j N              Parallelism for make (default: $(nproc)).
#   --name TAG        Name tag for output files. Copies final .img/.zip to
#                     builds/OrangeFox-R11.3-{TAG}-{family}.img/zip
#                     Without --name, copies with original filenames.
#
# This script:
#   1. Resolves source tree root (3 levels up from this script)
#   2. Optionally cleans previous build output
#   3. Sources build/envsetup.sh
#   4. Sets DEVICE_BUILD_FLAG if --family given (skips interactive menu)
#   5. Runs lunch twrp_pixels-ap2a-eng
#   6. Builds recovery: mka adbd vendorbootimage [-j N]
#      For gs201/gs101: also builds keymint-service.trusty
#   7. Copies final artifacts to builds/

set -eo pipefail

for var in ${!FOX_@} ${!OF_@} ${!TARGET_@} ${!TW_@}; do     unset "$var"; done
unset DEVICE_BUILD_FLAG

# --- Resolve paths ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# device/google/pixels/ → go up 3 levels to source root
SOURCE_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

# --- Parse arguments ---
FAMILY=""
CLEAN=true
JOBS="$(nproc)"
BUILD_NAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --family)
            shift
            FAMILY="${1:-}"
            if [[ -z "$FAMILY" ]]; then
                echo "ERROR: --family requires an argument (gs201|zuma|zumapro|gs101)"
                exit 1
            fi
            case "$FAMILY" in
                gs201|zuma|zumapro|gs101) ;;
                *)
                    echo "ERROR: unknown family '$FAMILY'. Valid: gs201, zuma, zumapro, gs101"
                    exit 1
                    ;;
            esac
            shift
            ;;
        --notrm)
            CLEAN=false
            shift
            ;;
        -j)
            shift
            JOBS="${1:-$(nproc)}"
            shift
            ;;
        -j[0-9]*)
            JOBS="${1#-j}"
            shift
            ;;
        --name)
            shift
            BUILD_NAME="${1:-}"
            if [[ -z "$BUILD_NAME" ]]; then
                echo "ERROR: --name requires an argument"
                exit 1
            fi
            shift
            ;;
        -h|--help)
            sed -n '2,26p' "$0"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "=============================================="
echo "  OrangeFox Recovery Build Script"
echo "=============================================="
echo "  Source root: $SOURCE_ROOT"
echo "  Family:     ${FAMILY:-<interactive>}"
echo "  Name:       ${BUILD_NAME:-<auto>}"
echo "  Clean:      $CLEAN"
echo "  Jobs:       $JOBS"
echo "=============================================="

cd "$SOURCE_ROOT"

python device/google/pixels/patch.py --mod

if [ ! -f "external/guava/Android.bp" ] || [ ! -f "external/gflags/Android.bp" ]; then
    if ! repo sync -c -d --force-sync external/gflags external/guava; then
        echo "ERROR: repo sync failed. Please check your network connection and try again."
        exit 1
    fi
fi

# --- Clean previous build output ---
PRODUCT_OUT="out/target/product/pixels"
if [[ "$CLEAN" == "true" && -d "$PRODUCT_OUT" ]]; then
    echo "[build] Cleaning $PRODUCT_OUT ..."
    rm -rf "$PRODUCT_OUT"
    echo "[build] Clean done."
fi

# --- Set DEVICE_BUILD_FLAG before sourcing envsetup ---
# This pre-exports the flag so vendorsetup.sh skips the interactive menu
# (it checks if DEVICE_BUILD_FLAG is already set on timeout path).
if [[ -n "$FAMILY" ]]; then
    export DEVICE_BUILD_FLAG="$FAMILY"
    echo "[build] Pre-set DEVICE_BUILD_FLAG=$FAMILY"
fi

# --- Source build environment ---
# AOSP's envsetup.sh uses uninitialized variables and may have benign non-zero
# returns, so we disable strict error handling for the sourcing/lunch phase.
echo "[build] Sourcing build/envsetup.sh ..."
set +e
source build/envsetup.sh

# --- Lunch ---
echo "[build] Running lunch twrp_pixels-ap2a-eng ..."
lunch twrp_pixels-ap2a-eng
set -eo pipefail

# --- Verify platform selection ---
echo "[build] DEVICE_BUILD_FLAG=${DEVICE_BUILD_FLAG:-<not set>}"

# --- Build targets ---
BUILD_TARGETS="adbd vendorbootimage"

# gs201 needs C++ keymint source-built
if [[ "${DEVICE_BUILD_FLAG:-}" == "gs201" ]]; then
    BUILD_TARGETS="$BUILD_TARGETS android.hardware.security.keymint-service.trusty"
    echo "[build] gs201: adding keymint-service.trusty to build targets"
fi

# gs101 hooks (future): stock vendor_boot patching, additional fstab
if [[ "${DEVICE_BUILD_FLAG:-}" == "gs101" ]]; then
    echo "[build] gs101: stock vendor_boot patch mode (VENDOR_BOOT_PATCH_STOCK=true)"
    export VENDOR_BOOT_PATCH_STOCK=true
    BUILD_TARGETS="$BUILD_TARGETS android.hardware.security.keymint-service.trusty"
    echo "[build] gs101: adding keymint-service.trusty to build targets"
fi

echo "=============================================="
echo "  Build targets: $BUILD_TARGETS"
echo "  Parallelism:   -j$JOBS"
echo "=============================================="

mka $BUILD_TARGETS -j"$JOBS"

echo ""
echo "=============================================="
echo "  Build complete!"
echo "  Output: $SOURCE_ROOT/$PRODUCT_OUT/"
echo "=============================================="

# --- Copy artifacts to builds/ ---
BUILDS_DIR="$SOURCE_ROOT/builds"
mkdir -p "$BUILDS_DIR"

LATEST_IMG=$(find "$SOURCE_ROOT/$PRODUCT_OUT" -maxdepth 1 -name 'OrangeFox-*.img' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)
LATEST_ZIP=$(find "$SOURCE_ROOT/$PRODUCT_OUT" -maxdepth 1 -name 'OrangeFox-*.zip' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)

FAMILY_TAG="${DEVICE_BUILD_FLAG:-unknown}"

if [[ -n "$BUILD_NAME" ]]; then
    # Named build: OrangeFox-R11.3-{name}-{family}.ext
    if [[ -n "$LATEST_IMG" ]]; then
        cp "$LATEST_IMG" "$BUILDS_DIR/OrangeFox-R11.3-${BUILD_NAME}-${FAMILY_TAG}.img"
        echo "[build] Copied: builds/OrangeFox-R11.3-${BUILD_NAME}-${FAMILY_TAG}.img"
    fi
    if [[ -n "$LATEST_ZIP" ]]; then
        cp "$LATEST_ZIP" "$BUILDS_DIR/OrangeFox-R11.3-${BUILD_NAME}-${FAMILY_TAG}.zip"
        echo "[build] Copied: builds/OrangeFox-R11.3-${BUILD_NAME}-${FAMILY_TAG}.zip"
    fi
else
    # No name: copy with original filenames
    if [[ -n "$LATEST_IMG" ]]; then
        cp "$LATEST_IMG" "$BUILDS_DIR/OrangeFox-R11.3-${FAMILY_TAG}.img"
        echo "[build] Copied: builds/OrangeFox-R11.3-${FAMILY_TAG}.img"
    fi
    if [[ -n "$LATEST_ZIP" ]]; then
        cp "$LATEST_ZIP" "$BUILDS_DIR/OrangeFox-R11.3-${FAMILY_TAG}.zip"
        echo "[build] Copied: builds/OrangeFox-R11.3-${FAMILY_TAG}.zip"
    fi
fi

if [[ -z "$LATEST_IMG" && -z "$LATEST_ZIP" ]]; then
    echo "[build] WARNING: No OrangeFox artifacts found in $PRODUCT_OUT"
fi

echo "=============================================="
echo "  Artifacts in: $BUILDS_DIR/"
echo "=============================================="
