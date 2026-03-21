#!/sbin/sh
# ======================================================================
# Universal Tensor Torch Control (gs201 / zuma / zumapro)
# Fully dynamic I2C & GPIO discovery. Zero hardcoded paths!
# ======================================================================

LOGF="/tmp/recovery.log"
ACTION="$1"

log_msg() {
    echo "I:torch: $1" >> "$LOGF"
    echo "$1"
}

discover_hardware() {
    local sys_dir=$(ls -d /sys/bus/i2c/devices/*-0063 2>/dev/null | head -n 1)
    if [ -z "$sys_dir" ]; then
        log_msg "ERROR: LM3644 (*-0063) not found on any I2C bus."
        return 1
    fi
    local dev_name=$(basename "$sys_dir")
    I2C_BUS=$(echo "$dev_name" | cut -d'-' -f1)
    I2C_ADDR="0x$(echo "$dev_name" | cut -d'-' -f2)"
    local pins_file=$(find /sys/firmware/devicetree/base/ -name "samsung,pins" 2>/dev/null | grep -iE "flash|torch" | head -n 1)
    if [ -z "$pins_file" ]; then
        log_msg "ERROR: Could not find flash pinctrl in Device Tree."
        return 1
    fi
    local pin_name=$(cat "$pins_file" 2>/dev/null | tr '\0' '\n' | grep "-" | head -n 1)
    if [ -z "$pin_name" ]; then
        log_msg "ERROR: Failed to read pin name from Device Tree."
        return 1
    fi
    local bank=${pin_name%-*}
    GPIO_OFFSET=${pin_name#*-}
    local chip_line=$(gpiodetect 2>/dev/null | grep "\[$bank\]")
    if [ -z "$chip_line" ]; then
        log_msg "ERROR: Could not map bank [$bank] using gpiodetect."
        return 1
    fi
    GPIO_CHIP=$(echo "$chip_line" | cut -d' ' -f1)
    log_msg "HW Found -> I2C: Bus $I2C_BUS, Addr $I2C_ADDR | GPIO: $GPIO_CHIP offset $GPIO_OFFSET ($pin_name)"
    return 0
}

torch_on() {
    if ! discover_hardware; then
        log_msg "Aborting torch ON."
        return 1
    fi
    log_msg "Waking up flash chip via GPIO..."
    gpioset "$GPIO_CHIP" "${GPIO_OFFSET}=1" 2>/dev/null
    sleep 0.1
    log_msg "Sending I2C commands..."
    i2cset -f -y "$I2C_BUS" "$I2C_ADDR" 0x05 0x3F b 2>/dev/null
    i2cset -f -y "$I2C_BUS" "$I2C_ADDR" 0x01 0x0B b 2>/dev/null
    log_msg "Torch is ON."
}

torch_off() {
    if ! discover_hardware; then
        log_msg "Aborting torch OFF."
        return 1
    fi
    log_msg "Turning off LED via I2C..."
    i2cset -f -y "$I2C_BUS" "$I2C_ADDR" 0x01 0x00 b 2>/dev/null
    log_msg "Putting chip to sleep via GPIO..."
    gpioset "$GPIO_CHIP" "${GPIO_OFFSET}=0" 2>/dev/null
    log_msg "Torch is OFF."
}

# Точка входа
case "$ACTION" in
    on)  torch_on ;;
    off) torch_off ;;
    *)   log_msg "Usage: $0 on|off" ;;
esac