#!/system/bin/sh
#
# gpu_stage.sh - copy the phone's own PowerVR stack into RAM for the GPU renderer.
#
# Run by init at early-boot, before the recovery service. It maps vendor, vendor_dlkm
# and system (see stage_lib.sh), copies the driver, its firmware and everything they
# link into the ramdisk and loads the kernel module. minuitwrp_gl loads the driver into
# the sphal linker namespace, so anything the driver links has to end up under
# /vendor/lib64 unless the recovery shares it (see /system/etc/ld.config.txt). That
# includes the phone's own libbinder and libbinder_ndk, as the driver's libraries need
# newer ones than this recovery has. Nothing here starts gralloc: the renderer draws
# into the display's own buffers.

NAME=gpu
LOG=/dev/logs/gpu_stage.log
. /system/bin/stage_lib.sh

egl=$(getprop ro.hardware.egl)
[ -n "$egl" ] || { echo "ro.hardware.egl is not set"; exit 1; }
shared=" $(sed -n 's/^namespace\.sphal\.link\.default\.shared_libs = //p' /system/etc/ld.config.txt | tr : ' ') "
[ "$shared" != "  " ] || { echo "ld.config.txt has no sphal namespace"; exit 1; }

attach vendor || fail "cannot map vendor$suffix"
attach vendor_dlkm || fail "cannot map vendor_dlkm$suffix"
attach system || fail "cannot map system$suffix"
V=$WORK/vendor
S=$WORK/system
[ -d $S/system/lib64 ] && S=$S/system

# pvrsrvkm asks for its firmware while it probes.
for fw in $V/firmware/rgx.*; do
    put $fw /vendor/firmware/${fw##*/} || fail "cannot copy ${fw##*/}"
done
load /vendor/lib/modules/pvrsrvkm.ko || fail "cannot load pvrsrvkm"

queue=""
seen=" "
want() {
    put $1 $2 || fail "cannot copy $1"
    queue="$queue $2"
}
for f in lib64/egl/libEGL_$egl.so lib64/egl/libGLESv2_$egl.so; do
    [ -f $V/$f ] || fail "vendor has no $f"
    want $V/$f /vendor/$f
done
# libIMGegl opens the GLESv1 library by path instead of linking it.
f=lib64/egl/libGLESv1_CM_$egl.so
[ -f $V/$f ] && want $V/$f /vendor/$f
[ -f $V/etc/powervr.ini ] && put $V/etc/powervr.ini /vendor/etc/powervr.ini

while [ -n "$queue" ]; do
    set -- $queue
    f=$1
    shift
    queue="$*"
    for lib in $(readelf -d $f | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
        case "$seen$shared" in *" $lib "*) continue ;; esac
        seen="$seen$lib "
        src=""
        for dir in lib64 lib64/egl lib64/hw; do
            [ -f $V/$dir/$lib ] && { src=$V/$dir/$lib; dst=/vendor/$dir/$lib; break; }
        done
        # The rest comes from system: libnativewindow, libui, libbinder and the graphics
        # interface libraries, in the versions the driver was built against.
        if [ -z "$src" ] && [ -f $S/lib64/$lib ]; then
            src=$S/lib64/$lib
            dst=/vendor/lib64/$lib
        fi
        [ -n "$src" ] || fail "$lib, needed by ${f##*/}, is on neither vendor nor system"
        want $src $dst
    done
done

# libIMGegl opens its GLES libraries under /system/vendor, which only Android has.
[ -e /system/vendor ] || ln -s /vendor /system/vendor

release
echo "staged $(echo $staged | wc -w) files, done at $(cut -d' ' -f1 /proc/uptime)s"
