#!/sbin/sh

# reflash_twrp.sh -- Reflash OrangeFox to both vendor_boot slots, per slot.
# Works on the malibu (Pixel 11) family -- same partition layout.
#
# The recovery fragment and the container come from the vendor_boot we are
# BOOTED FROM: that image is proven bootable by definition, and reading it off
# the block device gives the fragment exactly as it was built (no reconstruction,
# and no LGZ-decompressed files, which is what the boot-time ramdisk snapshot
# existed to avoid). The fragment is build-independent, so it is grafted onto
# EACH slot's OWN first-stage: for every slot the current vendor_boot is read,
# its platform is stripped to first-stage, and the fragment is placed beside it.
# Each slot therefore keeps its own build's first-stage, and after an OTA the
# updated slot keeps the new build's.
#
# Rebuilding the running slot reproduces its own image, so that slot matches and
# is skipped, which keeps a known-good slot while the other one is rewritten.
# stdout is captured by twrpRepacker and displayed in the recovery UI.

FOLDER="/tmp/reflash_recovery"
LOGF="/tmp/reflash_twrp.log"

exec 2>>"$LOGF"

_log() { printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null)" "$*" >> "$LOGF"; }
_die() {
    echo "ERROR: $*"
    _log "FATAL: $*"
    exit 1
}

_log "========== reflash_twrp START =========="
_log "device=$(getprop ro.hardware 2>/dev/null)  uptime=$(awk '{print $1}' /proc/uptime 2>/dev/null)s"

echo "- Starting reflash current recovery (per-slot graft)"

for _bin in magiskboot busybox dd sha256sum; do
    command -v "$_bin" >/dev/null 2>&1 || _die "Required binary not found: $_bin"
done
_log "binaries OK"

slot=$(getprop ro.boot.slot_suffix)
[ -n "$slot" ] || slot=$(grep -o 'androidboot.slot_suffix = "[^"]*"' /proc/bootconfig 2>/dev/null | cut -d'"' -f2)
[ -n "$slot" ] || _die "could not determine the running slot"

DEV_A="/dev/block/by-name/vendor_boot_a"
DEV_B="/dev/block/by-name/vendor_boot_b"
RUNDEV="/dev/block/by-name/vendor_boot$slot"
[ -b "$DEV_A" ] || _die "Block device not found: $DEV_A"
[ -b "$DEV_B" ] || _die "Block device not found: $DEV_B"
[ -b "$RUNDEV" ] || _die "Block device not found: $RUNDEV"
_log "block devices OK (running slot $slot)"

rm -rf "$FOLDER"
mkdir -p "$FOLDER/src" || _die "Cannot create $FOLDER/src"

# magiskboot returns 3 for a vendor_boot unpack; only 1 is a real failure.
mb() { local rc=0; magiskboot "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" != 1 ]; }

# --- the running vendor_boot: proven bootable, so it supplies both the recovery
#     fragment and the container every slot is rebuilt into ---
echo "- Reading the running vendor_boot (slot $slot) as the source..."
dd if="$RUNDEV" of="$FOLDER/src/vb.img" bs=4M 2>>"$LOGF" || _die "could not read $RUNDEV"
( cd "$FOLDER/src" && mb unpack vb.img )
OUR_RECOVERY="$FOLDER/src/vendor_ramdisk/recovery.cpio"
[ -f "$OUR_RECOVERY" ] || _die "the running vendor_boot has no recovery fragment (not an OrangeFox image?)"
magiskboot cpio "$OUR_RECOVERY" "exists init.recovery.pixel_common.rc" >/dev/null 2>&1 \
    || _die "the running recovery fragment is not ours (missing init.recovery.pixel_common.rc)"
_log "source recovery.cpio size=$(stat -c %s "$OUR_RECOVERY" 2>/dev/null) sha=$(sha256sum "$OUR_RECOVERY" | awk '{print $1}')"

# Strip a platform ramdisk cpio to first-stage: drop system/lib64, res, the real
# toolbox binaries (keep init and the toybox symlinks) and any device-typed vintf
# manifest. A no-op on an already-reduced (OrangeFox) platform. magiskboot's own
# cpio plus busybox awk, no system cpio; the rm list is applied in one rewrite.
STRIP="$FOLDER/strip"
strip_platform() {
    local RC=$1 p
    rm -rf "$STRIP"; mkdir -p "$STRIP"
    { echo "rm -r system/lib64"; echo "rm -r res"; } > "$STRIP/cmds"
    magiskboot cpio "$RC" "ls system/bin" 2>/dev/null \
        | busybox awk -F'\t' '$1 ~ /^-/ && $NF != "system/bin/init" { print "rm " $NF }' >> "$STRIP/cmds"
    magiskboot cpio "$RC" "ls system/etc/vintf/manifest" 2>/dev/null \
        | busybox awk -F'\t' '$1 ~ /^-/ && $NF ~ /\.xml$/ { print $NF }' > "$STRIP/mans"
    while IFS= read -r p; do
        magiskboot cpio "$RC" "extract $p $STRIP/m.xml" >/dev/null 2>&1 || continue
        busybox grep -q 'type="device"' "$STRIP/m.xml" && echo "rm $p" >> "$STRIP/cmds"
    done < "$STRIP/mans"
    set --
    while IFS= read -r p; do set -- "$@" "$p"; done < "$STRIP/cmds"
    magiskboot cpio "$RC" "$@" >/dev/null 2>&1 || true
}

# Graft the recovery fragment onto one slot's own first-stage and flash it.
process_slot() {
    local dev=$1 name=$2
    local sdir="$FOLDER/$name" bdir="$FOLDER/build_$name"

    # The slot we booted from is the source: its first-stage is its own and its
    # recovery fragment is the one being propagated, so it is already in the end
    # state. Never rewrite it -- that keeps a known-good slot no matter what the
    # rebuild of the other slot turns out to be.
    if [ "$dev" = "$RUNDEV" ]; then
        echo "- $name is the running slot (the source), leaving it alone"
        _log "$name skipped (running slot / source)"
        return 0
    fi

    rm -rf "$sdir" "$bdir"
    mkdir -p "$sdir" "$bdir" || { echo "  ! $name: cannot create work dirs"; return 1; }

    echo "- $name: reading current vendor_boot..."
    dd if="$dev" of="$sdir/vb.img" bs=4M 2>>"$LOGF" || { echo "  ! $name read failed"; return 1; }
    ( cd "$sdir" && mb unpack vb.img )
    [ -f "$sdir/vendor_ramdisk/ramdisk.cpio" ] || { echo "  ! $name has no platform fragment"; return 1; }

    # Unpack the source image in the build dir so every component (header, dtb,
    # bootconfig) comes from the proven container, then replace only the two
    # ramdisk fragments.
    cp -f "$FOLDER/src/vb.img" "$bdir/vb.img"
    ( cd "$bdir" && mb unpack vb.img )
    [ -f "$bdir/vendor_ramdisk/recovery.cpio" ] || { echo "  ! $name: container lost its recovery fragment"; return 1; }

    cp -f "$sdir/vendor_ramdisk/ramdisk.cpio" "$bdir/vendor_ramdisk/ramdisk.cpio"
    echo "- $name: stripping its platform to first-stage..."
    strip_platform "$bdir/vendor_ramdisk/ramdisk.cpio"
    cp -f "$OUR_RECOVERY" "$bdir/vendor_ramdisk/recovery.cpio"

    local pb rb mib
    pb=$(stat -c %s "$bdir/vendor_ramdisk/ramdisk.cpio")
    rb=$(stat -c %s "$bdir/vendor_ramdisk/recovery.cpio")
    mib=$(( (pb + rb) / 1048576 ))
    echo "- $name: recovery-mode ramdisk ${mib} MiB"
    [ "$mib" -lt 100 ] || { echo "  ! $name ramdisk ${mib} MiB exceeds the ~100 MiB load limit"; return 1; }

    ( cd "$bdir" && mb repack vb.img new-boot.img )
    [ -s "$bdir/new-boot.img" ] || { echo "  ! $name repack produced no image"; return 1; }
    local isz ihash blks vhash
    isz=$(stat -c %s "$bdir/new-boot.img")
    [ "$isz" -gt 1048576 ] || { echo "  ! $name image suspiciously small ($isz bytes)"; return 1; }
    ihash=$(sha256sum "$bdir/new-boot.img" | awk '{print $1}')
    _log "$name new-boot.img size=$isz sha=$ihash"

    # magiskboot repack is deterministic, so a slot that already holds the exact
    # image we just built is left alone. Rebuilding the running slot reproduces
    # its own image, so the slot we booted from is skipped and stays known-good.
    if [ "$(head -c "$isz" "$sdir/vb.img" | sha256sum | awk '{print $1}')" = "$ihash" ]; then
        echo "- $name already identical, skipping write"
        _log "$name skipped (image identical)"
        return 0
    fi

    echo "- $name: flashing..."
    dd if="$bdir/new-boot.img" of="$dev" bs=4M conv=fsync 2>>"$LOGF" || { echo "  ! $name write failed"; return 1; }
    sync

    blks=$(( (isz + 4194303) / 4194304 ))
    vhash=$(dd if="$dev" bs=4M count="$blks" 2>/dev/null | head -c "$isz" | sha256sum | awk '{print $1}')
    [ "$vhash" = "$ihash" ] || { echo "  ! $name verify FAILED (sha mismatch)"; _log "$name verify FAIL exp=$ihash got=$vhash"; return 1; }
    echo "- $name: verified OK"
    _log "$name flashed + verified"
    return 0
}

RC_OVERALL=0
process_slot "$DEV_A" vendor_boot_a || RC_OVERALL=1
process_slot "$DEV_B" vendor_boot_b || RC_OVERALL=1
[ "$RC_OVERALL" = 0 ] || _die "one or more slots failed to reflash"

echo "- Recovery reflashed to both slots (per-slot graft) successfully"
_log "========== reflash_twrp END OK ==========="
exit 0
