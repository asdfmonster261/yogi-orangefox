#!/bin/sh
#
#   runatinit.sh - OrangeFox Recovery early-init device identity script.
#
#   This file is part of the OrangeFox Recovery Project
#   Copyright (C) 2024-2026 The OrangeFox Recovery Project
#
#   OrangeFox is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   any later version.
#
# Runs in on early-init phase via exec, BEFORE:
#   - on init (USB controller, Trusty TEE)
#   - on early-boot (USB gadget strings use ${ro.product.model})
#   - TWRP data.cpp (DataManager reads ro.product props)
#
# Detects device codename from ro.hardware and applies:
#   1. Family-common properties (zuma_common.prop)
#   2. Device-specific properties (shiba.prop, husky.prop, etc.)
#   3. LGZ decompression of build-time compressed zip payloads
#   4. Magisk binary extraction and link creation
#
# This ensures correct device identity for MTP/USB enumeration and UI
# BEFORE the USB gadget writes ${ro.product.model} to configfs.
#

PROPS_DIR="/system/etc/device_props"

apply_prop_file() {
    local file="$1"
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        case "$line" in
            \#*|"") continue ;;
        esac
        key="${line%%=*}"
        value="${line#*=}"
        [ -n "$key" ] && resetprop "$key" "$value"
    done < "$file"
}

# Patches /system/etc/twrp.flags before TWRP reads it: Process_Fstab() runs
# before runatboot.sh. Adds the OTG block device as the next sdX letter after
# the last internal UFS disk, and drops by-name entries absent on this device.
#
# Safety: if ueventd coldboot is not done yet (by-name empty after wait),
# the prune step is skipped entirely - never prunes on an empty /dev/block.
fix_twrp_flags() {
    local flags_file="/system/etc/twrp.flags"
    [ -f "$flags_file" ] || return
    local LOG="/tmp/recovery.log"
    local i last_blk last_letter next_letter tmp line blk part

    # Wait up to 3 seconds for ueventd to create /dev/block/sd? nodes.
    # runatinit runs at early-init; ueventd coldboot is concurrent and usually
    # completes within 1-2 seconds. The loop exits immediately on first hit.
    i=0
    while [ "$i" -lt 3 ]; do
        ls /dev/block/sd? >/dev/null 2>&1 && break
        sleep 1
        i=$((i + 1))
    done

    # --- 1. USB OTG device auto-detection ---
    # UFS internal disks: sda, sdb, sdc, ... OTG gets the next letter.
    last_blk=$(ls /dev/block/sd? 2>/dev/null | sort | tail -1)
    if [ -n "$last_blk" ]; then
        last_letter="${last_blk##*sd}"
        next_letter=$(printf '%s' "$last_letter" | tr 'abcdefghijklmnopqrstuvwxy' 'bcdefghijklmnopqrstuvwxyz')
        if [ "$next_letter" != "$last_letter" ]; then
            sed -i "/usb_otg/s|/dev/block/sd[a-z][0-9]*|/dev/block/sd${next_letter}1|" "$flags_file"
            echo "I:twrp.flags: USB OTG -> /dev/block/sd${next_letter}1 (last internal: ${last_blk##*/})" >> "$LOG"
        fi
    else
        echo "W:twrp.flags: No /dev/block/sd? after wait, USB OTG entry unchanged" >> "$LOG"
    fi

    # --- 2. Prune by-name entries absent on this device ---
    # Safety guard: skip prune if by-name is not populated yet.
    if ! ls /dev/block/platform/*/by-name/ >/dev/null 2>&1; then
        echo "W:twrp.flags: by-name not ready, skipping partition prune" >> "$LOG"
        return
    fi

    tmp="${flags_file}.tmp"
    : > "$tmp"
    while IFS= read -r line; do
        case "$line" in
            \#*|"") printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        # awk: portable field extraction; busybox awk is always available in recovery
        blk=$(printf '%s\n' "$line" | awk '{print $3}')
        case "$blk" in
            /dev/block/platform/*/by-name/*)
                part="${blk##*/}"
                # A/B slotselect entries use the base name (e.g. "boot") in twrp.flags,
                # but by-name contains only suffixed symlinks (boot_a / boot_b).
                # Keep the entry if the base name OR the _a suffixed name exists.
                if ls /dev/block/platform/*/by-name/"$part" >/dev/null 2>&1 ||
                   ls /dev/block/platform/*/by-name/"${part}_a" >/dev/null 2>&1; then
                    printf '%s\n' "$line" >> "$tmp"
                else
                    echo "I:twrp.flags: Pruned absent partition: $part" >> "$LOG"
                fi
                ;;
            *)
                printf '%s\n' "$line" >> "$tmp"
                ;;
        esac
    done < "$flags_file"
    mv -f "$tmp" "$flags_file"
}

setenforce 0

device_code=$(getprop ro.hardware)
case "$device_code" in
    panther|cheetah|lynx|gs201)      family="gs201" ;;
    shiba|husky|akita|zuma)          family="zuma" ;;
    tokay|komodo|caiman|tegu|zumapro) family="zumapro" ;;
    *)                                family="" ;;
esac

if [ -n "$family" ]; then
    apply_prop_file "${PROPS_DIR}/${family}_common.prop"
fi
apply_prop_file "${PROPS_DIR}/${device_code}.prop"
if [ "$family" = "gs201" ] && [ -f /system/etc/twrp_gs201.flags ]; then
    cp -f /system/etc/twrp_gs201.flags /system/etc/twrp.flags
fi
fix_twrp_flags
lgz_decompress_zips() {
    local manifest="/lgz_zip_manifest.txt"
    [ -f "$manifest" ] || return 0

    local lgz="/system/bin/lgz"
    [ -x "$lgz" ] || return 0

    echo "I:lgz-zip: Decompressing zip contents..." >> /tmp/recovery.log

    while IFS= read -r zippath; do
        case "$zippath" in \#*|"") continue ;; esac
        [ -f "$zippath" ] || continue

        tmpdir=$(mktemp -d /tmp/lgz_zip.XXXXXX)

        if unzip -q -o "$zippath" -d "$tmpdir" 2>/dev/null; then
            find "$tmpdir" -type f | while IFS= read -r f; do
                if "$lgz" decompress "$f" "${f}.dec" 2>/dev/null; then
                    mv -f "${f}.dec" "$f"
                fi
            done
            rm -f "${zippath}.tmp"
            (cd "$tmpdir" && zip -0 -r -q "${zippath}.tmp" .) 2>/dev/null

            if [ -f "${zippath}.tmp" ]; then
                mv -f "${zippath}.tmp" "$zippath"
                echo "I:lgz-zip: Restored: $zippath" >> /tmp/recovery.log
            fi
        fi

        rm -rf "$tmpdir"
    done < "$manifest"
}

unzip_magiskboot_binary() {
    local zip="$1"
    [ -f "$zip" ] || return
    mkdir -p /tmp/magisk_unzip
    cd /tmp/magisk_unzip || return
    unzip -q "$zip"
    cp lib/arm64-v8a/libmagiskboot.so /system/bin/magiskboot_29
    cp lib/arm64-v8a/libmagiskboot.so /system/bin/magiskboot
    cp lib/arm64-v8a/libbusybox.so /system/bin/busybox
    chmod 777 /system/bin/magiskboot_29
    chmod 777 /system/bin/magiskboot
    chmod 777 /system/bin/busybox
    rm -f /system/bin/ln
    /system/bin/busybox ln -s /system/bin/busybox /system/bin/ln
    cd /tmp || return
    rm -rf /tmp/magisk_unzip
}

lgz_decompress_zips
TARGET_MAGISK_ZIP=""
for _f in /system/bin/Magisk-*.zip; do
    [ -f "$_f" ] && TARGET_MAGISK_ZIP="$_f" && break
done
if [ -n "$TARGET_MAGISK_ZIP" ]; then
    unzip_magiskboot_binary "$TARGET_MAGISK_ZIP"
else
    echo "W:magisk: No Magisk zip found in /system/bin, skipping binary extraction" >> /tmp/recovery.log
fi

setprop servicemanager.ready true
resetprop servicemanager.ready true

exit 0
