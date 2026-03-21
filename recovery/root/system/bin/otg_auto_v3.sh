#!/system/bin/sh
# ============================================================================
# otg_auto_v3.sh — Automatic OTG via VBUS detection (default HOST)
# ============================================================================
#
# APPROACH: Default to HOST mode at boot. Detect PC by external VBUS presence.
#   When VBUS appears → PC is supplying power → switch to DEVICE (ADB).
#   When VBUS disappears → nothing or OTG device → switch to HOST.
#
# HOW IT WORKS:
#   - Boot: immediately switch to HOST (OTG devices work right away)
#   - Poll /sys/class/power_supply/usb/online (or present)
#   - VBUS=1: external power source = PC → DEVICE mode
#   - VBUS=0: no external power → HOST mode (we supply VBUS via CHARGER_MODE)
#
# PROS: Simplest detection. OTG works immediately at boot without any cable.
#        Mouse/keyboard work from the first second.
# CONS: False positive if using powered OTG hub (hub supplies VBUS).
#        Not reliable with Y-cables or external power adapters on OTG.
#
# REQUIRES: otg_patch.sh already ran (shim + USBSW_CONNECT loaded)
# ============================================================================

TAG="otg_auto_v3"
POLL=1

OTG_ID="/sys/devices/platform/11210000.usb/dwc3_exynos_otg_id"
CHARGER_VALUE="/sys/kernel/debug/gvotables/CHARGER_MODE/force_int_value"
CHARGER_ACTIVE="/sys/kernel/debug/gvotables/CHARGER_MODE/force_int_active"
UDC_FILE="/config/usb_gadget/g1/UDC"
UDC_NAME="11210000.dwc3"
TCPC_BUS=11
TCPC_ADDR=0x25
VBUS_PATHS="/sys/class/power_supply/usb/online
/sys/class/power_supply/usb/present
/sys/class/power_supply/usb-charger/online"

CURRENT_MODE=""
VBUS_FILE=""
log() {
    echo "$TAG: $1" > /dev/kmsg 2>/dev/null
    echo "$TAG: $1"
}

find_vbus_path() {
    for p in $VBUS_PATHS; do
        if [ -f "$p" ]; then
            VBUS_FILE="$p"
            log "Using VBUS path: $VBUS_FILE"
            return 0
        fi
    done
    log "ERROR: No VBUS sysfs path found!"
    return 1
}

get_vbus() {
    if [ -z "$VBUS_FILE" ]; then
        echo "0"
        return
    fi
    cat "$VBUS_FILE" 2>/dev/null || echo "0"
}

dump_state() {
    log "=== STATE DUMP ==="
    log "CURRENT_MODE: $CURRENT_MODE"
    log "VBUS ($VBUS_FILE): $(get_vbus)"
    log "otg_id: $(cat $OTG_ID 2>/dev/null || echo N/A)"
    log "UDC: $(cat $UDC_FILE 2>/dev/null || echo N/A)"
    log "ffs.ready: $(getprop sys.usb.ffs.ready)"
    log "usb devices: $(ls /sys/bus/usb/devices/ 2>/dev/null | tr '\n' ' ')"
    log "================="
}

switch_to_host() {
    if [ "$CURRENT_MODE" = "host" ]; then return; fi
    log ">>> SWITCHING TO HOST MODE <<<"
    echo "" > "$UDC_FILE" 2>/dev/null
    echo 49 > "$CHARGER_VALUE" 2>/dev/null
    echo 1 > "$CHARGER_ACTIVE" 2>/dev/null
    echo 0 > "$OTG_ID" 2>/dev/null
    CURRENT_MODE="host"
}

switch_to_device() {
    if [ "$CURRENT_MODE" = "device" ]; then return; fi
    log ">>> SWITCHING TO DEVICE MODE <<<"
    echo 0 > "$CHARGER_ACTIVE" 2>/dev/null
    echo 1 > "$OTG_ID" 2>/dev/null
    resetprop sys.usb.ffs.ready 1
    CURRENT_MODE="device"
    resetprop sys.usb.ffs.ready 1
}

log "Starting (VBUS detection, default HOST)..."
resetprop sys.usb.patch_dwc3 0
find_vbus_path
if [ -z "$VBUS_FILE" ]; then
    log "FATAL: Cannot detect VBUS. Trying TypeC partner as fallback."
fi
log "Waiting 3s for boot to settle..."
sleep 3
INITIAL_VBUS=$(get_vbus)
log "Initial VBUS: $INITIAL_VBUS"

if [ "$INITIAL_VBUS" = "1" ]; then
    log "PC detected at boot (VBUS=1), starting in DEVICE mode"
    switch_to_device
else
    log "No PC at boot (VBUS=0), starting in HOST mode"
    switch_to_host
fi

PREV_VBUS="$INITIAL_VBUS"

while true; do
    VBUS=$(get_vbus)
    if [ "$VBUS" != "$PREV_VBUS" ]; then
        log "VBUS change: $PREV_VBUS -> $VBUS"
        if [ "$VBUS" = "1" ]; then
            switch_to_device
        else
            switch_to_host
        fi

        PREV_VBUS="$VBUS"
    fi

    sleep "$POLL"
done
