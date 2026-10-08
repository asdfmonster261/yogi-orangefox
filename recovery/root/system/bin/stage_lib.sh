#
# stage_lib.sh - shared by the early-boot staging scripts, which set NAME and LOG and
# then source this file.
#
# A staging script copies what the recovery needs from the booted slot's own
# partitions into the ramdisk. It maps them read-only under dm names of its own and
# drops every mount and mapping again when it is done, so no partition is left busy.

WORK=/dev/stage-$NAME

mkdir -p /dev/logs $WORK
exec >> $LOG 2>&1
echo "start at $(cut -d' ' -f1 /proc/uptime)s"

suffix=$(getprop ro.boot.slot_suffix)
case $suffix in
    _a) slot=0 ;;
    _b) slot=1 ;;
    *) echo "no slot suffix"; exit 1 ;;
esac

maps=""
mounts=""
staged=""

release() {
    for m in $mounts; do umount $m || echo "could not unmount $m"; done
    for d in $maps; do dmctl delete $d > /dev/null || echo "could not delete $d"; done
    rm -rf $WORK
}

fail() {
    echo "failed: $*"
    # A half-staged driver is worse than none: without one the renderer stays on its
    # software path and WLAN stays off.
    for f in $staged; do rm -f $f; done
    release
    exit 1
}
trap 'fail "timed out"' TERM

# Map partition $1 of the booted slot from super's metadata and mount it read-only
# on $WORK/$1. The recovery maps the same partitions itself later, under their own names.
attach() {
    local name=stage_${NAME}_$1 table dev i=0
    # At early-boot this has failed with nothing logged, where the same steps later
    # succeed, so keep every error and give it a few seconds.
    while :; do
        table=$(lpdump --slot=$slot /dev/block/by-name/super | awk -v p=$1$suffix '
            $1 == "Name:" { cur = $2; next }
            cur == p && $4 == "linear" { printf "linear %d %d /dev/block/by-name/%s %d ", $1, $3 - $1 + 1, $5, $6 }')
        [ -n "$table" ] && dmctl create $name -ro $table > /dev/null && break
        echo "$1$suffix not mappable at $(cut -d' ' -f1 /proc/uptime)s, table '$table'"
        i=$((i + 1))
        [ $i -lt 20 ] || return 1
        sleep 0.25
    done
    maps="$name $maps"
    dev=$(dmctl getpath $name)
    i=0
    while [ ! -b "$dev" ] && [ $i -lt 50 ]; do
        sleep 0.1
        i=$((i + 1))
    done
    mkdir -p $WORK/$1
    mount -t erofs -o ro $dev $WORK/$1 2> /dev/null || mount -t ext4 -o ro $dev $WORK/$1 || return 1
    mounts="$WORK/$1 $mounts"
    echo "$1$suffix mapped at $dev"
}

# Copy $1 to $2, leaving anything the ramdisk already has alone.
put() {
    [ -e $2 ] && return 0
    mkdir -p ${2%/*}
    cp -p $1 $2 || return 1
    staged="$staged $2"
}

# Find module file $1 on the attached dlkm partitions: stock keeps them flat under
# lib/modules, but a custom kernel may flash a kernel install tree under
# lib/modules/<version> instead.
modfile() {
    local p f
    for p in vendor_dlkm system_dlkm; do
        [ -d $WORK/$p/lib/modules ] || continue
        f=$WORK/$p/lib/modules/$1
        [ -f $f ] || f=$(find $WORK/$p/lib/modules -name $1 -type f 2> /dev/null | head -n 1)
        [ -n "$f" ] && { echo $f; return 0; }
    done
    return 1
}

# Load module $1, a file name or a path as modules.dep writes it, after the modules it
# needs, from the modules.dep of whichever tree holds it. Every partition a dependency
# may sit on has to be attached.
load() {
    local name=${1##*/} file root re deps dep
    grep -q "^$(echo ${name%.ko} | tr - _) " /proc/modules && return 0
    file=$(modfile $name) || { echo "$name is not on an attached partition"; return 1; }
    root=${file%%/lib/modules/*}/lib/modules
    re=$(echo $name | sed 's/[.]/\\./g')
    for dep in $root/modules.dep $root/*/modules.dep; do
        [ -f $dep ] || continue
        deps=$(sed -nE "s#^(.*/)?$re: *##p" $dep | head -n 1)
        [ -n "$deps" ] && break
    done
    for dep in $deps; do
        load $dep || return 1
    done
    insmod $file
}
