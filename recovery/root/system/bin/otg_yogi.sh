#!/system/bin/sh
#
# otg_yogi.sh -- USB-OTG host for the malibu (Pixel 11) family in recovery.
#
# The kernel registers the Type-C port dual-role (tcpm overrides the sink-only
# state the bootloader forces in recovery), so the port votes TCPCI:host on
# attach. google-usb-role-sw also needs the AoC's vote, which goes host only once
# the AoC usb_control service runs -- started by aocd.
#
# aocd, its 6 libs and aoc_usb_driver.ko are the device's OWN vendor binaries
# (vendor + vendor_dlkm); nothing proprietary ships in this zip. They are copied
# into tmpfs and the module is loaded into kernel memory, so a vendor unmount
# (e.g. while flashing a zip) cannot pull them out from under the running daemon.

LOGF=/tmp/recovery.log
log(){ echo "I:otg: $1" >> "$LOGF"; }
RAM=/tmp/aoc; mkdir -p "$RAM/lib"
slot=$(getprop ro.boot.slot_suffix)
[ -n "$slot" ] || slot=$(grep -o 'androidboot.slot_suffix = "[^"]*"' /proc/bootconfig 2>/dev/null | cut -d'"' -f2)
MV=/dev/otg_mnt/vendor; MD=/dev/otg_mnt/vdlkm; mkdir -p "$MV" "$MD"

staged(){ [ -f "$RAM/aocd" ] && [ -f "$RAM/aoc_usb_driver.ko" ]; }

# Copy the AoC runtime out of the device's own vendor/vendor_dlkm into RAM. The
# dm-mapper nodes are not up when this service first fires, so it is retried from
# the loop until they appear; the copies then survive a later vendor unmount.
stage(){
  if [ ! -f "$RAM/aocd" ] && mount -o ro /dev/block/mapper/vendor$slot "$MV" 2>/dev/null; then
    cp -f "$MV/bin/aocd" "$RAM/" 2>/dev/null
    for l in libaoc libbase libevent aoc_aconfig_flags_c_lib libaconfig_storage_read_api_cc libc++; do
      cp -f "$MV/lib64/$l.so" "$RAM/lib/" 2>/dev/null
    done
    umount "$MV" 2>/dev/null
    chmod 0755 "$RAM/aocd" 2>/dev/null
  fi
  if [ ! -f "$RAM/aoc_usb_driver.ko" ] && mount -o ro /dev/block/mapper/vendor_dlkm$slot "$MD" 2>/dev/null; then
    ko=$(find "$MD" -name aoc_usb_driver.ko 2>/dev/null | head -1)
    [ -n "$ko" ] && cp -f "$ko" "$RAM/"
    umount "$MD" 2>/dev/null
  fi
  staged
}

aoc_ready(){ [ "$(cat /sys/devices/platform/*.aoc/verify_aoc_responsive 2>/dev/null)" = responsive ]; }
uc(){ for f in $(find /sys/devices/platform/*.aoc -name services 2>/dev/null); do cat "$f" 2>/dev/null; done | grep -q usb_control; }

# The removable USB disk's letter drifts across attach/detach, so keep a stable
# symlink for /usb_otg to point at (see twrp_malibu.flags).
usb_disk(){
  for d in /sys/block/sd*; do
    [ "$(cat "$d/removable" 2>/dev/null)" = 1 ] || continue
    readlink -f "$d/device" 2>/dev/null | grep -q usb || continue
    b=/dev/block/$(basename "$d")
    if [ -b "${b}1" ]; then echo "${b}1"; else echo "$b"; fi
    return 0
  done
  return 1
}

# aocd's startup is flaky: a given instance may start usb_control, or come up but never
# start it (seen alive and idle 20s+), or die. A fresh instance is what eventually gets
# the service up, so relaunch one until usb_control appears, killing the previous attempt
# first so they do not pile up. usb_control persists once up, so stop relaunching then.
mkdir -p /dev/socket
voted=0
while true; do
  if ! staged; then stage && log "staged aocd + 6 libs + module into RAM"; fi
  if staged; then
    [ -d /sys/module/aoc_usb_driver ] || { insmod "$RAM/aoc_usb_driver.ko" 2>>"$LOGF" && log "aoc_usb_driver loaded"; }
    if uc; then
      [ "$voted" = 1 ] || { voted=1; log "aocd up; AOC vote live"; }
    elif aoc_ready; then
      kill $(pidof aocd) 2>/dev/null
      LD_LIBRARY_PATH="$RAM/lib":/system/lib64 "$RAM/aocd" >/dev/null 2>&1 &
      sleep 4
      uc && { voted=1; log "aocd up; AOC vote live"; }
    fi
    P=$(usb_disk); if [ -n "$P" ] && [ -b "$P" ]; then
      [ "$(readlink /dev/block/otg-usb 2>/dev/null)" = "$P" ] || { ln -sf "$P" /dev/block/otg-usb; log "otg-usb -> $P"; }
    fi
  fi
  sleep 3
done
