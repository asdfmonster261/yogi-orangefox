#!/sbin/sh
# ======================================================================
# Universal Tensor Torch Control (gs201 / zuma / zumapro / gs305-malibu)
# Fully dynamic I2C & GPIO discovery. Zero hardcoded paths.
# ======================================================================

LOGF="/tmp/recovery.log"
ACTION="$1"
LWIS_MODE=0

log_msg() {
    echo "I:torch: $1" >> "$LOGF"
    echo "$1"
}

# Some Tensor devices (e.g. malibu/yogi) wire the LM3644 as a
# google,lwis-i2c-device. The LWIS camera driver never probes in recovery, so
# the chip is not a registered I2C client and there is no samsung,pins GPIO to
# find. Read the bus and address straight from the device tree and drive it
# directly. It also needs its enable-gpios asserted (LWIS would do that on
# device-open); the pinctrl default does NOT hold it high in recovery.
discover_lwis_flash() {
    local dtb=/sys/firmware/devicetree/base f fn=""
    for f in $(find "$dtb" -name "flash@*" -type d 2>/dev/null); do
        grep -aq "lwis-i2c-device" "$f/compatible" 2>/dev/null && { fn="$f"; break; }
    done
    [ -n "$fn" ] || return 1
    [ -f "$fn/i2c-addr" ] && [ -f "$fn/i2c-bus" ] || return 1

    # i2c-addr is a big-endian u32; the low byte is the 7-bit address.
    I2C_ADDR="0x$(od -An -tx1 < "$fn/i2c-addr" 2>/dev/null | tr -dc '0-9a-fA-F' | tail -c 2)"

    # i2c-bus is a phandle to the I2C controller; match it to a linux i2c-N.
    local busph b ofn
    busph=$(od -An -tx1 < "$fn/i2c-bus" 2>/dev/null | tr -dc '0-9a-fA-F')
    I2C_BUS=""
    for b in /sys/bus/i2c/devices/i2c-*; do
        ofn=$(readlink -f "$b/of_node" 2>/dev/null)
        [ -f "$ofn/phandle" ] || continue
        if [ "$(od -An -tx1 < "$ofn/phandle" 2>/dev/null | tr -dc '0-9a-fA-F')" = "$busph" ]; then
            I2C_BUS="${b##*i2c-}"; break
        fi
    done
    [ -n "$I2C_BUS" ] || return 1

    # enable-gpios cells are <phandle line flags>; resolve the phandle to a
    # gpiochipN just like the i2c bus above, so torch_on can drive it high.
    GPIO_CHIP=""; GPIO_OFFSET=""
    if [ -f "$fn/enable-gpios" ]; then
        local eg enph g gof
        eg=$(od -An -tx1 < "$fn/enable-gpios" 2>/dev/null | tr -dc '0-9a-fA-F')
        enph=$(printf '%s' "$eg" | cut -c1-8)
        GPIO_OFFSET=$(printf '%d' "0x$(printf '%s' "$eg" | cut -c9-16)")
        for g in /sys/bus/gpio/devices/gpiochip*; do
            gof=$(readlink -f "$g/of_node" 2>/dev/null)
            [ -f "$gof/phandle" ] || continue
            if [ "$(od -An -tx1 < "$gof/phandle" 2>/dev/null | tr -dc '0-9a-fA-F')" = "$enph" ]; then
                GPIO_CHIP=$(basename "$g"); break
            fi
        done
    fi

    LWIS_MODE=1
    log_msg "LWIS flash -> I2C bus $I2C_BUS addr $I2C_ADDR, enable ${GPIO_CHIP:-none}/${GPIO_OFFSET:-none}"
    return 0
}

discover_hardware() {
    local sys_dir=$(ls -d /sys/bus/i2c/devices/*-0063 2>/dev/null | head -n 1)
    if [ -z "$sys_dir" ]; then
        # No registered LM3644 client; try the LWIS device-tree path.
        discover_lwis_flash && return 0
        log_msg "ERROR: LM3644 (*-0063) not found and no LWIS flash node either."
        return 1
    fi
    LWIS_MODE=0
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
    if [ -n "$GPIO_CHIP" ]; then
        log_msg "Waking up flash chip via GPIO..."
        gpioset "$GPIO_CHIP" "${GPIO_OFFSET}=1" 2>/dev/null
        sleep 0.1
    fi
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
    if [ -n "$GPIO_CHIP" ]; then
        log_msg "Putting chip to sleep via GPIO..."
        gpioset "$GPIO_CHIP" "${GPIO_OFFSET}=0" 2>/dev/null
    fi
    log_msg "Torch is OFF."
}

case "$ACTION" in
    on)  torch_on ;;
    off) torch_off ;;
    *)   log_msg "Usage: $0 on|off" ;;
esac
