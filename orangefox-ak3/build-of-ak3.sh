#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# Build the flashable OrangeFox recovery installer zip (repack model). It ships
# OrangeFox's raw vendor_boot plus arm64 magiskboot and busybox; on device,
# anykernel.sh grafts OrangeFox's recovery onto the user's own vendor_boot
# first-stage and writes it back to the active slot. No fastboot, no host-side
# assembly, one zip for any build. Flash it from KernelFlasher or OrangeFox.
#
# Usage: build-of-ak3.sh <orangefox-raw-vendor_boot.img> <output.zip>
#   the raw image is OrangeFox's two-fragment vendor_boot (the "unassembled" one
#   from create-orangefox-yogi.sh / the release), NOT an assembled/flashable image.

set -eu
OFVB=${1:?usage: build-of-ak3.sh <of-raw-vendor_boot.img> <out.zip>}
OUT=${2:?}
HERE=$(cd "$(dirname "$0")" && pwd)
[ -f "$OFVB" ] || { echo "no such OrangeFox image: $OFVB" >&2; exit 1; }
OFVB=$(readlink -f "$OFVB")
OUT=$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")

AK3_URL=https://github.com/osm0sis/AnyKernel3/archive/refs/heads/master.tar.gz
# v31.0 for parity with the kernel zip; any recent magiskboot handles vendor_boot,
# but keeping one version avoids surprises. The apk carries arm64 (for the zip) and
# x86_64 (to validate the input here).
MAGISK_URL=https://github.com/topjohnwu/Magisk/releases/download/v31.0/Magisk-v31.0.apk

work=$(mktemp -d); trap 'rm -rf "$work"' EXIT
stage="$work/ak3"; mkdir -p "$stage"

# AK3 upstream, trimmed to what a repack-only zip uses.
curl -sfL "$AK3_URL" | tar -xz -C "$stage" --strip-components=1
rm -rf "$stage/.github" "$stage/README.md" "$stage/modules" "$stage/patch" "$stage/ramdisk"

# arm64 busybox + magiskboot for the zip, x86_64 magiskboot to validate the input.
# AK3's own tools are 32-bit and dead on this arm64-only device; anykernel.sh only
# runs busybox and magiskboot, so those are the two to replace.
apk=${MAGISK_APK:-$work/magisk.apk}
[ -f "$apk" ] || curl -sfL "$MAGISK_URL" -o "$apk"
unzip -o -q "$apk" \
	'lib/arm64-v8a/libbusybox.so' \
	'lib/arm64-v8a/libmagiskboot.so' \
	'lib/x86_64/libmagiskboot.so' -d "$work/mg"
mv "$work/mg/lib/arm64-v8a/libbusybox.so"    "$stage/tools/busybox"
mv "$work/mg/lib/arm64-v8a/libmagiskboot.so" "$stage/tools/magiskboot"
mbhost="$work/mg/lib/x86_64/libmagiskboot.so"
chmod 755 "$stage/tools/busybox" "$stage/tools/magiskboot" "$mbhost"

for f in busybox magiskboot; do
	case "$(file -b "$stage/tools/$f")" in
		*"ELF 64-bit"*aarch64*) ;;
		*) echo "$f is not arm64 - the zip would fail on device" >&2; exit 1 ;;
	esac
done

# Validate the input is OrangeFox's two-fragment vendor_boot with our malibu recovery,
# not a stock or already-assembled image. Same check the on-device script trusts.
v="$work/v"; mkdir -p "$v"; cp "$OFVB" "$v/vb.img"
( cd "$v" && "$mbhost" unpack vb.img >/dev/null 2>&1 ) || true
[ -f "$v/vendor_ramdisk/recovery.cpio" ] \
	|| { echo "$OFVB is not a two-fragment OrangeFox vendor_boot (no recovery fragment)" >&2; exit 1; }
"$mbhost" cpio "$v/vendor_ramdisk/recovery.cpio" "exists init.recovery.pixel_common.rc" >/dev/null 2>&1 \
	|| { echo "OrangeFox recovery fragment is missing our recovery init - wrong image?" >&2; exit 1; }

cp "$OFVB" "$stage/vendor_boot-of.img"

# Our repack flasher, with the shipped image's checksum stamped in so a truncated
# download aborts instead of grafting a partial recovery.
cp "$HERE/anykernel.sh" "$stage/anykernel.sh"
osha=$(sha256sum "$stage/vendor_boot-of.img" | cut -d' ' -f1)
sed -i "s/^OFVBSHA=.*/OFVBSHA=$osha;/" "$stage/anykernel.sh"
grep -q "^OFVBSHA=$osha;" "$stage/anykernel.sh" || { echo "failed to stamp image checksum" >&2; exit 1; }

python3 - "$stage" "$OUT" <<'PY'
import os, sys, zipfile
root, out = sys.argv[1], sys.argv[2]
files=[]
for dp,_,fns in os.walk(root):
    for fn in fns:
        files.append(os.path.relpath(os.path.join(dp,fn), root))
with zipfile.ZipFile(out,"w",zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for rel in sorted(files):
        full=os.path.join(root,rel)
        zi=zipfile.ZipInfo(rel, date_time=(2026,1,1,0,0,0))
        zi.external_attr=(os.stat(full).st_mode & 0xFFFF) << 16
        zi.compress_type=zipfile.ZIP_DEFLATED
        with open(full,'rb') as f: z.writestr(zi, f.read())
print(f"wrote {out} ({os.path.getsize(out):,} bytes)")
PY
