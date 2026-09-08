#!/system/bin/sh
# setup_cpu_temp.sh — Find the CPU "BIG" cluster thermal zone and create a stable
# /dev/thermal_cpu symlink for TWRP's TW_CUSTOM_CPU_TEMP_PATH.
#
# Thermal zone numbering varies in recovery, so enumerate all zones, match the
# BIG/prime cluster by "type" name, and symlink the winner. Fallback: zone0.

TARGET=/dev/thermal_cpu

rm -f "$TARGET"

for z in /sys/class/thermal/thermal_zone*; do
    [ -d "$z" ] || continue
    t=$(cat "$z/type" 2>/dev/null) || continue
    case "$t" in
        BIG|CLUSTER2|CLUSTER_BIG|cpu_big|CPU-Big|prime|PRIME)
            ln -sf "$z/temp" "$TARGET"
            exit 0
            ;;
    esac
done

ln -sf /sys/class/thermal/thermal_zone0/temp "$TARGET"
