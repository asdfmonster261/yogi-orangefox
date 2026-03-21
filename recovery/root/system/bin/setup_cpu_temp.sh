#!/system/bin/sh
# setup_cpu_temp.sh - Find the CPU "BIG" cluster thermal zone and create a stable
# /dev/thermal_cpu symlink for TWRP's TW_CUSTOM_CPU_TEMP_PATH.
#
# Problem: thermal zone numbering differs across Tensor chip generations in recovery:
#   zuma  (G3, Pixel 8):   cp_thermal_zone.ko loaded  -> zone0=BIG ✓
#   gs201 (G2, Pixel 7):   cp_thermal_zone.ko loaded  -> zone0 may vary
#   zumapro (G4, Pixel 9): cp_thermal_zone.ko absent  -> zone0 unknown
#
# Solution: enumerate all zones, match by "type" name, symlink the winner.
#
# Known BIG-cluster zone type names across Tensor generations:
#   "BIG"      - Tensor G3 (zuma, Pixel 8)  [confirmed live]
#   "BIG"      - Tensor G2 (gs201, Pixel 7) [expected same Samsung Exynos driver]
#   "CLUSTER2" - Tensor G4 (zumapro, Pixel 9) [ARM DynamIQ cluster naming]
#   "cpu-0-1-us" / "cpu-0-0-us" - fallback generic names on some kernels
# Fallback: zone0 (TWRP default) if no known name matched.

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
