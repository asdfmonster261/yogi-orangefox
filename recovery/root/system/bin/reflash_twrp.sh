#!/sbin/sh

# reflash_twrp.sh — Reflash recovery to both vendor_boot slots from ramdisk snapshot.
# Works on all Zuma SoC Pixels (shiba/husky/akita) — same partition layout.
#
# The snapshot at /dev/ramdisk_snapshot/ preserves the exact ramdisk state
# from boot time (before LGZ decompression), so the repacked image is
# byte-identical to the original.
# stdout is captured by twrpRepacker and displayed in the recovery UI.

SNAP="/dev/ramdisk_snapshot"

echo "- Starting reflash current recovery (snapshot-based)"

# Verify snapshot exists
if [ ! -d "$SNAP" ]; then
    echo "ERROR: Ramdisk snapshot not found at $SNAP"
    echo "ERROR: Cannot reflash without snapshot. Was ramdisk_snapshot run at boot?"
    exit 1
fi

folder=/tmp/reflash_recovery
rm -rf "$folder"
mkdir -p "$folder/vendor_ramdisk"

device_code=$(getprop ro.hardware)

# Bootconfig
echo "androidboot.usbcontroller=11210000.dwc3" >> "$folder/bootconfig"

case "$device_code" in
    panther|cheetah|lynx|pantah|gs201)
        echo "androidboot.boot_devices=14700000.ufs" >> "$folder/bootconfig"
        ;;
    *)
        echo "androidboot.boot_devices=13200000.ufs" >> "$folder/bootconfig"
        ;;
esac
echo "androidboot.load_modules_parallel=true" >> "$folder/bootconfig"

# DFE fstab patching - modify snapshot copies
if ! [ -f /FFiles/check_dfe_and_reflash ] && ! [ -f /sdcard/Fox/check_dfe_and_reflash ]; then
    for f in "$SNAP/first_stage_ramdisk/system/etc"/fstab*; do
        [ -f "$f" ] || continue
        if grep -q "/vendor/etc/init/hw" "$f"; then
            echo "- Patching fstab: $(basename "$f")"
            sed -i '/\/vendor\/etc\/init\/hw/d' "$f"
        fi
    done
fi

# check_dfe_and_reflash handling
RECOVERY_LIST="$SNAP/recovery_file_list.txt"
FSTAGE_LIST="$SNAP/first_stage_file_list.txt"

if [ -f /sdcard/Fox/check_dfe_and_reflash ]; then
    mkdir -p "$SNAP/FFiles"
    touch "$SNAP/FFiles/check_dfe_and_reflash"
    if [ -f "$RECOVERY_LIST" ] && ! grep -q "FFiles/check_dfe_and_reflash" "$RECOVERY_LIST"; then
        echo "FFiles/check_dfe_and_reflash" >> "$RECOVERY_LIST"
    fi
fi

if [ -f /FFiles/check_dfe_and_reflash ]; then
    mkdir -p "$SNAP/FFiles"
    cp /FFiles/check_dfe_and_reflash "$SNAP/FFiles/" 2>/dev/null
    if [ -f "$RECOVERY_LIST" ] && ! grep -q "FFiles/check_dfe_and_reflash" "$RECOVERY_LIST"; then
        echo "FFiles/check_dfe_and_reflash" >> "$RECOVERY_LIST"
    fi
else
    if [ -f "$RECOVERY_LIST" ] && grep -q "FFiles/check_dfe_and_reflash" "$RECOVERY_LIST"; then
        sed -i '/FFiles\/check_dfe_and_reflash/d' "$RECOVERY_LIST"
    fi
fi

# Unmount partitions that may interfere
umount -fl /vendor 2>/dev/null
umount -fl /system_root 2>/dev/null

# Create cpio archives from snapshot directory
echo "- Creating recovery ramdisk cpio from snapshot..."
cd "$SNAP"

if ! grep -q "first_stage_file_list.txt" "$RECOVERY_LIST" ; then
    echo "first_stage_file_list.txt" >> "$RECOVERY_LIST"
fi
if ! grep -q "ramdisk_snapshot_manifest.txt" "$RECOVERY_LIST" ; then
        echo "ramdisk_snapshot_manifest.txt" >> $RECOVERY_LIST
fi

cpio -H newc -o < "$RECOVERY_LIST" > "$folder/vendor_ramdisk/recovery.cpio" 2>/dev/null
echo "- Creating first_stage ramdisk cpio from snapshot..."
cpio -H newc -o < "$FSTAGE_LIST" > "$folder/vendor_ramdisk/ramdisk.cpio" 2>/dev/null

# Repack vendor_boot image
echo "- Decompressing base vendor_boot image..."
cd "$folder"
magiskboot_29 decompress "$SNAP/system/bin/nboot.lz4" ./empty.img &> /dev/null
echo "- Repacking vendor_boot image..."
magiskboot_29 repack "$folder/empty.img" &> /dev/null

# Flash to both slots
echo "- Flashing to vendor_boot_a..."
cat new-boot.img > /dev/block/by-name/vendor_boot_a
echo "- Flashing to vendor_boot_b..."
cat new-boot.img > /dev/block/by-name/vendor_boot_b

echo "- Recovery reflashed to both slots successfully"

exit 0