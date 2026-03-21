#!/bin/sh
#
#   runatboot.sh - OrangeFox Recovery early-boot script for malibu Pixels.
#
#   This file is part of the OrangeFox Recovery Project
#   Copyright (C) 2024-2026 The OrangeFox Recovery Project
#
#   OrangeFox is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   any later version.
#
#   Please maintain this if you use this script or any part of it
#
# Executed after runatinit.sh (which handles device identity and props).
# Responsible for:
#   1. LGZ decompression of build-time compressed zip payloads
#   2. Device detection (ro.hardware -> module list per device)
#   3. A/B slot detection and vendor_dlkm module loading (touch, haptics)
#   4. Vendor firmware copy (CS40L26 haptics) with slot fallback
#   5. Magisk binary extraction and link creation
#

# =========================================================================
# A/B slot detection - sets suffix/unsuffix/slot/unslot globals
# =========================================================================
slot_detect() {
    suffix=$(getprop ro.boot.slot_suffix)
    if [ -z "$suffix" ]; then
        suffix=$(bootctl get-current-slot | xargs bootctl get-suffix 2>/dev/null)
    fi
    case "$suffix" in
        _a) 
            unsuffix=_b
            slot=0
            unslot=1
            ;;
        _b) 
            unsuffix=_a 
            slot=1
            unslot=0
            ;;
    esac
}

# =========================================================================
# Module loading - load touch/haptics .ko modules from vendor_dlkm partition.
# Strategy: try current slot -> opposite slot -> fallback /system/modules_touch
# Uses lptools_new to map logical partitions if block device is missing.
# =========================================================================
modules_touch_install() {
    mkdir -p /dev/modules_inject/vendor_dlkm_a /dev/modules_inject/vendor_dlkm_b

    try_load_modules_from_path() {
        local path="$1"
        local loaded_any=0
        local missing_modules=""
        
        for module in $modules_touch; do
            files_finded=$(find "$path" 2>/dev/null | grep "${module}.ko$")
            if [ -z "$files_finded" ]; then
                missing_modules="$missing_modules $module"
                continue
            fi
            
            for f in $files_finded; do
                if insmod "$f" 2>>"$LOGF"; then
                    echo "I:modules: $module loaded successfully from $f" >> "$LOGF"
                    loaded_any=1
                else
                    echo "E:modules: Cannot load $module from $f" >> "$LOGF"
                    missing_modules="$missing_modules $module"
                fi
            done
        done
        
        echo "$missing_modules"
        return $loaded_any
    }

    check_modules_loaded() {
        local missing=""
        for module in $modules_touch; do
            local mod_name=$(echo "$module" | tr '-' '_')
            if ! lsmod | grep -q "$mod_name"; then
                missing="$missing $module"
            fi
        done
        if [ -n "$missing" ]; then
            echo "E:modules: Missing modules: $missing" >> "$LOGF"
            return 1
        else
            echo "I:modules: All modules loaded successfully" >> "$LOGF"
            return 0
        fi
    }

    try_slot() {
        local blk="$1"
        local mnt="$2"
        local slot_name="$3"
        local slot_num="$4"

        if [ ! -b "$blk" ]; then
            echo "W:modules: $blk not found, trying to map..." >> "$LOGF"
            if ! lptools_new --slot "$slot_num" --suffix "$slot_name" --map "vendor_dlkm$slot_name" ; then
                echo "E:modules: Failed to map $blk" >> "$LOGF"
                return 1
            fi
        fi

        if mount -r "$blk" "$mnt"; then
            echo "I:modules: Mounted $blk on $mnt" >> "$LOGF"
            missing=$(try_load_modules_from_path "$mnt")
            umount "$mnt"
            echo "I:modules: Unmounted $mnt" >> "$LOGF"
            [ -z "$missing" ] && return 0
            echo "W:modules: Missing modules after $slot_name slot attempt: $missing" >> "$LOGF"
            return 1
        else
            echo "E:modules: Cannot mount $blk" >> "$LOGF"
            return 1
        fi
    }

    echo "I:modules: Trying current slot $suffix" >> "$LOGF"
    try_slot "/dev/block/mapper/vendor_dlkm$suffix" "/dev/modules_inject/vendor_dlkm$suffix" "$suffix" "$slot"
    res=$?

    if [ $res -ne 0 ]; then
        echo "I:modules: Trying opposite slot $unsuffix" >> "$LOGF"
        try_slot "/dev/block/mapper/vendor_dlkm$unsuffix" "/dev/modules_inject/vendor_dlkm$unsuffix" "$unsuffix" "$unslot"
    fi

    if ! check_modules_loaded; then
        echo "I:modules: Trying fallback /system/modules_touch" >> "$LOGF"
        missing=$(try_load_modules_from_path "/system/modules_touch")
        if ! check_modules_loaded; then
            echo "E:modules: Final failure, modules still missing: $missing" >> "$LOGF"
            echo "I:modules: Currently loaded modules:" >> "$LOGF"
            lsmod >> "$LOGF"
        fi
    fi
}

# =========================================================================
# Fix error 7: remove stale OTA metadata from /metadata/ota
# =========================================================================
fix_kerror7() {
    if ! mountpoint -q /metadata ; then
        mount /metadata
    fi
    if [ -d /metadata/ota ]; then
        rm -rf /metadata/ota
    fi
    umount /metadata
}

# =========================================================================
# Magisk: create zip links in OrangeFox file manager directories
# =========================================================================
magisk_link_to_OF_FILES() {
    Magisk_zip="$1"
    mkdir -p /FFiles/OF_Magisk/ /sdcard/Fox/FoxFiles
    cp -f "$Magisk_zip" /FFiles/OF_Magisk/Magisk.zip
    cp -f "$Magisk_zip" /FFiles/OF_Magisk/uninstall.zip
    magisk_on_data_media "$Magisk_zip" &
}

magisk_on_data_media(){
    local Magisk_zip="$1"
    while true; do
        if [ -d /data/media/0 ] && mountpoint -q /data; then
            if [ ! -f /data/media/0/Fox/FoxFiles/Magisk.zip ] || [ ! -f /sdcard/Fox/FoxFiles/uninstall.zip ]; then
                echo "I:magisk: Copying Magisk zip to /data/media/0 for sideload/install from stock recovery" >> "$LOGF"
                mkdir -pv /data/media/0/Fox/FoxFiles
                cp -f "$Magisk_zip" /data/media/0/Fox/FoxFiles/uninstall.zip
            fi
            if [ ! -f /data/media/0/Fox/FoxFiles/Magisk.zip ] || [ ! -f /sdcard/Fox/FoxFiles/Magisk.zip ]; then
                echo "I:magisk: Copying Magisk zip to /data/media/0 for sideload/install from stock recovery" >> "$LOGF"
                mkdir -pv /data/media/0/Fox/FoxFiles
                cp -f "$Magisk_zip" /data/media/0/Fox/FoxFiles/Magisk.zip
            fi
            
        fi
        sleep 2
    done
}

# =========================================================================
# Magisk: extract magiskboot binary from Magisk zip for reflash_twrp.sh
# =========================================================================
unzip_magiskboot_binary() {
    mkdir -p /tmp/magisk_unzip
    cd /tmp/magisk_unzip || return
    unzip -q "$TARGET_MAGISK_ZIP"
    cp lib/arm64-v8a/libmagiskboot.so /system/bin/magiskboot_29
    cp lib/arm64-v8a/libmagiskboot.so /system/bin/magiskboot
    chmod 777 /system/bin/magiskboot_29
    chmod 777 /system/bin/magiskboot
    cd /tmp || return
    rm -rf /tmp/magisk_unzip
}

# =========================================================================
# LGZ: Decompress zip archives whose contents were LGZ-compressed at build
# =========================================================================
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

            # Repack with store mode (fast, contents are already uncompressed)
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

find_magisk_zip() {
    local dir="$1"
    local file
    
    # Перебираем все файлы, подходящие под маску в указанной директории
    for file in "${dir}"/Magisk-*.zip; do
        # Проверяем, существует ли реально такой файл 
        # (защита от случая, когда файлов нет, и оболочка возвращает саму маску как строку)
        if [ -f "$file" ]; then
            echo "$file"
            return 0 # Прерываем поиск, возвращаем первый найденный файл
        fi
    done
    
    # Если ничего не нашли, функция просто завершится, вернув пустоту
}

# =========================================================================
# Main execution block
# =========================================================================

TARGET_MAGISK_ZIP=$(find_magisk_zip /system/bin)

setenforce 0
LOGF="/tmp/recovery.log"
chmod 777 /system/bin/*

# Decompress LGZ-packed zip contents before anything uses them.
# LGZ compresses zip payloads at build time to reduce ramdisk size.
lgz_decompress_zips

# Detect device codename from kernel-set ro.hardware property.
# This determines which modules to load, which props to set, etc.
device_code=$(getprop ro.hardware)

# Detect A/B slot: sets $suffix (_a/_b), $unsuffix, $slot (0/1), $unslot
slot_detect

# =========================================================================
# Device detection - set model and module list per ro.hardware
# =========================================================================
# DOF_SCREEN_H is set in init.recovery.{device}.rc (not here), because
# data.cpp reads it during DataManager::SetDefaultValues() which runs
# BEFORE runatboot.sh. By the time we get here the UI is already initialized.

case "$device_code" in
    # === gs201 - Tensor G2 (Pixel 7 family) ===
    panther)
        # Pixel 7 - Focaltech touch
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface focal_touch fps_touch_handler"
        ;;
    cheetah)
        # Pixel 7 Pro - Synaptics touch
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface syna_touch fps_touch_handler"
        ;;
    lynx)
        # Pixel 7a - Goodix + Focaltech touch (dual-source)
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface goodix_brl_touch focal_touch fps_touch_handler"
        ;;
    # === zuma - Tensor G3 (Pixel 8 family) ===
    shiba)
        # Pixel 8
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface sec_touch ftm5 goodix_brl_touch fps_touch_handler"
        ;;
    husky)
        # Pixel 8 Pro - same module set as shiba
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface sec_touch ftm5 goodix_brl_touch fps_touch_handler"
        ;;
    akita)
        # Pixel 8a - no sec_touch/ftm5 (Goodix only)
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface goodix_brl_touch fps_touch_handler"
        ;;
    # === zumapro - Tensor G4 (Pixel 9 family) ===
    tokay)
        # Pixel 9 - Synaptics + Samsung touch, QBT ultrasonic fingerprint
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp qbt_handler heatmap goog_touch_interface sec_touch syna_touch fps_touch_handler"
        ;;
    komodo)
        # Pixel 9 Pro XL - Synaptics + Samsung touch, QBT ultrasonic fingerprint
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp qbt_handler heatmap goog_touch_interface sec_touch syna_touch fps_touch_handler"
        ;;
    caiman)
        # Pixel 9 Pro - Synaptics + Samsung touch, QBT ultrasonic fingerprint
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp qbt_handler heatmap goog_touch_interface sec_touch syna_touch fps_touch_handler"
        ;;
    tegu)
        # Pixel 9a - Synaptics touch (no sec_touch, no QBT)
        modules_touch="stmvl53l1 lwis cl_dsp-core cs40l26-core cs40l26-i2c goodixfp heatmap goog_touch_interface syna_touch fps_touch_handler"
        ;;
    *)
        modules_touch=""
        ;;
esac

# DOF_SCREEN_H is set in init.recovery.{device}.rc (not here), because
# data.cpp reads it during DataManager::SetDefaultValues() which runs
# BEFORE runatboot.sh. By the time we get here the UI is already initialized.

if [ -n "$modules_touch" ]; then
    # =====================================================================
    # Vendor firmware copy - CS40L26 haptics firmware from vendor partition.
    # Uses same slot fallback logic as module loading: try current slot first,
    # then opposite slot, then by-name (unslotted) as last resort.
    # =====================================================================
    if [ ! -f /vendor/firmware/cs40l26.wmfw ]; then
        echo "I:vendor_fw: Copying haptics firmware from vendor partition..." >> "$LOGF"
        tmp_mnt="/tmp/vendor_fw_mnt"
        mkdir -p "$tmp_mnt" /vendor/firmware

        # try_mount_vendor_fw: try to mount vendor partition and copy firmware.
        # Uses same lptools_new mapping logic as modules_touch_install try_slot
        # for unmapped logical partitions (opposite slot is not mapped by init).
        try_mount_vendor_fw() {
            local blk="$1"
            local slot_name="$2"
            local slot_num="$3"

            if [ ! -b "$blk" ]; then
                echo "W:vendor_fw: $blk not found, trying to map..." >> "$LOGF"
                if ! lptools_new --slot "$slot_num" --suffix "$slot_name" --map "vendor$slot_name" ; then
                    echo "E:vendor_fw: Failed to map vendor$slot_name" >> "$LOGF"
                    return 1
                fi
            fi

            if mount -r "$blk" "$tmp_mnt" 2>>"$LOGF"; then
                if [ -f "$tmp_mnt/firmware/cs40l26.wmfw" ]; then
                    cp "$tmp_mnt"/firmware/* /vendor/firmware/ 2>>"$LOGF"
                    # cp "$tmp_mnt"/firmware/cs40l26* /vendor/firmware/ 2>>"$LOGF"
                    # cp "$tmp_mnt"/firmware/cl_dsp* /vendor/firmware/ 2>>"$LOGF"
                    echo "I:vendor_fw: Firmware copied from $blk" >> "$LOGF"
                    umount "$tmp_mnt" 2>/dev/null
                    return 0
                fi
                umount "$tmp_mnt" 2>/dev/null
                echo "W:vendor_fw: No cs40l26 firmware in $blk" >> "$LOGF"
            else
                echo "W:vendor_fw: Cannot mount $blk" >> "$LOGF"
            fi
            return 1
        }

        # Try current slot -> opposite slot -> unslotted by-name
        if try_mount_vendor_fw "/dev/block/mapper/vendor${suffix}" "$suffix" "$slot"; then
            : # success
        elif try_mount_vendor_fw "/dev/block/mapper/vendor${unsuffix}" "$unsuffix" "$unslot"; then
            : # success from opposite slot
        elif [ -b /dev/block/by-name/vendor ] && mount -r /dev/block/by-name/vendor "$tmp_mnt" 2>>"$LOGF"; then
            # Fallback: unslotted vendor (shouldn't exist on A/B, but just in case)
            cp "$tmp_mnt"/firmware/cs40l26* /vendor/firmware/ 2>>"$LOGF"
            cp "$tmp_mnt"/firmware/cl_dsp* /vendor/firmware/ 2>>"$LOGF"
            umount "$tmp_mnt" 2>/dev/null
            echo "I:vendor_fw: Firmware copied from /dev/block/by-name/vendor" >> "$LOGF"
        else
            echo "E:vendor_fw: Failed to copy firmware from any vendor slot" >> "$LOGF"
        fi

        rmdir "$tmp_mnt" 2>/dev/null
        ls /vendor/firmware/ >> "$LOGF" 2>&1
    fi

    # Load touch/haptics kernel modules from vendor_dlkm partition
    modules_touch_install

    # Disable runtime PM autosuspend on CS40L26 to keep haptic chip awake for FF vibration.
    # HSI2C bus differs per SoC family:
    #   gs201 (G2): 10d50000.hsi2c, i2c-0, address 0x43
    #   zuma  (G3): 10c80000.hsi2c, i2c-0, address 0x43
    #   zumapro (G4): TBD
    soc_family=$(getprop ro.recovery.soc_family)
    case "$soc_family" in
        gs201)
            cs40l26_pm="/sys/devices/platform/10d50000.hsi2c/i2c-0/0-0043/power/control"
            ;;
        zumapro)
            cs40l26_pm="/sys/devices/platform/10c80000.hsi2c/i2c-0/0-0043/power/control"
            ;;
        *)
            cs40l26_pm="/sys/devices/platform/10c80000.hsi2c/i2c-0/0-0043/power/control"
            ;;
    esac
    if [ -f "$cs40l26_pm" ]; then
        echo on > "$cs40l26_pm"
        echo "I:haptics: CS40L26 runtime PM set to 'on'" >> "$LOGF"
    fi
fi

# Log torch controller availability (LM3644 flash LED via I2C, controlled by torch_ctl.sh)
if [ -c "/dev/lwis-flash-lm3644" ]; then
    echo "I:torch: /dev/lwis-flash-lm3644 available, LM3644 I2C torch ready" >> "$LOGF"
else
    echo "W:torch: /dev/lwis-flash-lm3644 not found" >> "$LOGF"
fi

# Clean up stale OTA metadata that can cause boot loops (error 7)
fix_kerror7

# Create Magisk zip links in OrangeFox file manager locations
if [ -n "$TARGET_MAGISK_ZIP" ]; then
    magisk_link_to_OF_FILES "$TARGET_MAGISK_ZIP"
else
    echo "W:magisk: No Magisk zip found in /system/bin, skipping copy and link creation" >> "$LOGF"
fi

# Extract magiskboot binary from Magisk zip for reflash_twrp.sh
unzip_magiskboot_binary

exit 0