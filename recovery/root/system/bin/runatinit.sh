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
setprop servicemanager.ready true
resetprop servicemanager.ready true

exit 0
