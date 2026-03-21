#!/system/bin/sh
#
# otg_patch.sh — Reads otg_host_shim module status, injects it if necessary,
# activates it, and sets the system property for USB routing.
#
# Called by runatboot: 
# 1. Checks if the otg_host_shim module is loaded.
# 2. Injects it from /system/lib64/modules if missing.
# 3. Activates the host_ready flag.
# 4. Sets sys.usb.patch_dwc3=1 so RC property triggers can handle OTG switching.
#
# The actual host <-> device switching is done by init.recovery.usb.rc triggers
# reacting to sys.usb.config changes when sys.usb.patch_dwc3=1.
#

MODULE_PATH="/system/lib64/modules/otg_host_shim.ko"
PROC_SHIM="/proc/otg_host_shim"
PROC_READY="/proc/otg_host_ready"

# ==========================================
# Logging Helper Functions
# ==========================================
log_info() {
    echo "otg_patch: INFO: $1"
    # Write to kernel log buffer for dmesg visibility
    echo "otg_patch: INFO: $1" > /dev/kmsg 2>/dev/null
}

log_error() {
    echo "otg_patch: ERROR: $1"
    echo "otg_patch: ERROR: $1" > /dev/kmsg 2>/dev/null
}

log_info "Starting OTG patch routine..."

# ==========================================
# Mount Dependencies
# ==========================================
# Mount debugfs for gvotables access (CHARGER_MODE needed for OTG VBUS)
mount -t debugfs none /sys/kernel/debug 2>/dev/null
if [ $? -eq 0 ]; then
    log_info "debugfs successfully mounted or already available."
else
    log_error "Failed to mount debugfs."
fi

# ==========================================
# Module Injection
# ==========================================
if [ ! -f "$PROC_SHIM" ]; then
    log_info "/proc/otg_host_shim not found. Module is not loaded."
    log_info "Attempting to inject module from: $MODULE_PATH"
    
    if [ -f "$MODULE_PATH" ]; then
        insmod "$MODULE_PATH"
        INSMOD_STATUS=$?
        
        if [ $INSMOD_STATUS -eq 0 ]; then
            log_info "Successfully injected $MODULE_PATH."
        else
            log_error "insmod failed with exit code $INSMOD_STATUS."
            resetprop sys.usb.patch_dwc3 0
            exit 1
        fi
    else
        log_error "Module file not found at $MODULE_PATH!"
        resetprop sys.usb.patch_dwc3 0
        exit 1
    fi
else
    log_info "Module is already loaded (/proc/otg_host_shim exists)."
fi

# ==========================================
# Module Activation & Verification
# ==========================================
# The module loads in an inactive state by default. We need to activate it.
if [ -f "$PROC_SHIM" ]; then
    STATUS=$(cat "$PROC_READY" 2>/dev/null)
    
    if [ "$STATUS" != "1" ]; then
        log_info "host_ready is inactive. Activating via $PROC_SHIM..."
        echo "1" > "$PROC_SHIM" 2>/dev/null
        
        # Verify if activation was successful
        STATUS=$(cat "$PROC_READY" 2>/dev/null)
    fi

    # Final check and property set
    if [ "$STATUS" = "1" ]; then
        resetprop sys.usb.patch_dwc3 1
        log_info "host_ready is ACTIVE. Property sys.usb.patch_dwc3 set to 1."
    else
        resetprop sys.usb.patch_dwc3 0
        log_error "host_ready is NOT active despite activation attempt. Property sys.usb.patch_dwc3 set to 0."
    fi
else
    log_error "Critical error: Proc interfaces still missing after injection."
    resetprop sys.usb.patch_dwc3 0
    exit 1
fi

# ==========================================
# Type-C Data Path Switches (max77759 TCPC)
# ==========================================

USBSW_CTRL_REG="0x93"
USBSW_CONNECT="0x09"

log_info "Searching for max77759 TCPC device in sysfs..."

# Ищем любую папку устройства внутри драйвера (маска *-*)
TCPC_SYSFS_DIR=$(ls -d /sys/bus/i2c/drivers/max77759tcpc/*-* 2>/dev/null | head -n 1)

if [ -n "$TCPC_SYSFS_DIR" ]; then
    # Получаем имя папки (например, "11-0025" или "13-002a")
    TCPC_DEV_NAME=$(basename "$TCPC_SYSFS_DIR")
    
    # Разбиваем строку по дефису
    TCPC_I2C_BUS=$(echo "$TCPC_DEV_NAME" | cut -d'-' -f1)
    TCPC_I2C_ADDR_RAW=$(echo "$TCPC_DEV_NAME" | cut -d'-' -f2)
    
    # Добавляем префикс 0x для утилиты i2cset (получится, например, "0x0025")
    TCPC_I2C_ADDR="0x${TCPC_I2C_ADDR_RAW}"
    
    log_info "Found max77759 TCPC on bus: $TCPC_I2C_BUS with address: $TCPC_I2C_ADDR"
    log_info "Connecting USB data path switches..."
    
    # Выполняем команду с динамическими переменными
    i2cset -fy "$TCPC_I2C_BUS" "$TCPC_I2C_ADDR" "$USBSW_CTRL_REG" "$USBSW_CONNECT" b 2>/dev/null
    
    if [ $? -eq 0 ]; then
        log_info "USB data path switches connected successfully."
    else
        log_error "Failed to write USBSW_CTRL via i2cset. OTG host may not enumerate devices."
    fi
else
    log_error "max77759 TCPC driver or device not found. Skipping switch configuration."
fi

log_info "OTG patch routine finished."
exit 0