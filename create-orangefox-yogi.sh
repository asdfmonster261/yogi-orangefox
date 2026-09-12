#!/usr/bin/env bash
# Create a flashable OrangeFox vendor_boot for the Pixel 11 Pro Fold (yogi), matched to
# THIS device's current build. Self-contained; four steps:
#   1. get magiskboot (per-arch, out of a pinned Magisk apk, cached so it downloads once)
#   2. download the raw OrangeFox recovery image from the GitHub release
#   3. fetch this device's own stock vendor_boot from its OTA (only ~16 MiB, not the 3-4 GB zip)
#   4. graft OrangeFox's recovery onto the device's own first-stage -> a flashable image
# The result carries the device's own first-stage, so it always matches the build in use.
#
# Run on a Linux box (phone in adb) or in Termux on the phone itself.
# Needs: bash, curl, unzip, od, dd, xz, bzip2, sha256sum, coreutils. No python.
#
# Usage: create-orangefox-yogi.sh [--out FILE] [--raw FILE] [--build ID] [--device NAME]
set -euo pipefail

MAGISK_VER=v30.7
MAGISK_URL="https://github.com/topjohnwu/Magisk/releases/download/${MAGISK_VER}/Magisk-${MAGISK_VER}.apk"
RAW_URL="https://github.com/asdfmonster261/yogi-orangefox/releases/latest/download/OrangeFox-R12.0-yogi-unassembled.img"
OTA_PAGE='https://developers.google.com/android/ota'
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36'
COOKIE='devsite_wall_acks=nexus-ota-tos'

OUT="OrangeFox-R12.0-yogi-vendor_boot.img"; RAW=""; BUILD=""; DEVICE='yogi'
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT=$2; shift 2;;
    --raw) RAW=$2; shift 2;;
    --build) BUILD=$2; shift 2;;
    --device) DEVICE=$2; shift 2;;
    *) echo "unknown arg $1" >&2; exit 2;;
  esac
done
CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/yogi-of; mkdir -p "$CACHE"
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
case "$(uname -m)" in
  x86_64|amd64) ABI=x86_64;;
  aarch64|arm64|armv8*) ABI=arm64-v8a;;
  *) echo "unsupported host arch $(uname -m)" >&2; exit 1;;
esac

# ---- helpers ----
cfetch(){ curl -fsSL --retry 3 -A "$UA" -b "$COOKIE" "$@"; }
rget(){ local s=$1 l=$2 o=$3; cfetch -r "$s-$(( s + l - 1 ))" "$URL" -o "$o"; }
le_int(){ local v=0 sh=0 b; for b in $(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tu1 -v); do v=$(( v | (b << sh) )); sh=$(( sh + 8 )); done; echo "$v"; }
be_int(){ local v=0 b;   for b in $(dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -tu1 -v); do v=$(( (v << 8) | b )); done; echo "$v"; }
vfile(){ local f=$1 off=$2 sh=0 v=0 n=0 b; for b in $(dd if="$f" bs=1 skip="$off" count=10 2>/dev/null | od -An -tu1 -v); do v=$(( v | ((b & 127) << sh) )); n=$(( n + 1 )); if [ "$b" -lt 128 ]; then break; fi; sh=$(( sh + 7 )); done; VV=$v; VN=$(( off + n )); }
vhex(){ local h=$1 i=$2 sh=0 v=0 b; while :; do b=$(( 16#${h:i*2:2} )); v=$(( v | ((b & 127) << sh) )); i=$(( i + 1 )); if [ "$b" -lt 128 ]; then break; fi; sh=$(( sh + 7 )); done; VV=$v; VN=$i; }
mb(){ local rc=0; "$MB" "$@" >/dev/null 2>&1 || rc=$?; [ "$rc" != 1 ]; }
lspath(){ printf '%s' "${1##*$'\t'}"; }

# ---- step 3: fetch this device's stock vendor_boot straight out of the matching OTA ----
# payload.bin is STORED in the OTA zip; range-fetch the central directory to find it, walk
# the update_engine payload manifest (protobuf, by hand) and pull only vendor_boot's ops.
fetch_stock(){
  local OUTF=$1 PART=vendor_boot d="$W/f"; mkdir -p "$d"
  if [ -z "$BUILD" ]; then BUILD=$(getprop ro.build.id 2>/dev/null || adb shell getprop ro.build.id 2>/dev/null | tr -d '\r' || true); fi
  [ -n "$BUILD" ] || { echo "could not read ro.build.id (need a phone in adb, or pass --build)" >&2; exit 1; }
  local lb; lb=$(echo "$BUILD" | tr 'A-Z' 'a-z')
  echo "  device=$DEVICE build=$BUILD"
  URL=$(cfetch "$OTA_PAGE" | grep -oE "https://dl\.google\.com/dl/android/aosp/${DEVICE}-ota-${lb}-[0-9a-f]+\.zip" | head -1)
  [ -n "$URL" ] || { echo "no OTA link for $DEVICE / $BUILD on the OTA page" >&2; exit 1; }
  echo "  OTA: $URL"
  local TOTAL; TOTAL=$(cfetch -sI "$URL" | tr -d '\r' | awk 'tolower($1)=="content-length:"{print $2}' | tail -1)
  [ -n "$TOTAL" ] || { echo "no content-length" >&2; exit 1; }
  local t=65600; [ "$t" -gt "$TOTAL" ] && t=$TOTAL
  rget $(( TOTAL - t )) "$t" "$d/tail"
  local th ep eo cds cdo; th=$(od -An -tx1 -v "$d/tail" | tr -d ' \n')
  ep=$(echo "$th" | grep -bo '504b0506' | tail -1 | cut -d: -f1); [ -n "$ep" ] || { echo "no EOCD" >&2; exit 1; }
  eo=$(( ep / 2 )); cds=$(le_int "$d/tail" $(( eo + 12 )) 4); cdo=$(le_int "$d/tail" $(( eo + 16 )) 4)
  if [ "$cdo" = 4294967295 ] || [ "$cds" = 4294967295 ]; then echo "ZIP64 OTA not handled" >&2; exit 1; fi
  rget "$cdo" "$cds" "$d/cd"
  local co=0 sig method csz fnl exl cml lho name pay_lho=''
  while [ "$co" -lt "$cds" ]; do
    sig=$(le_int "$d/cd" "$co" 4); [ "$sig" = 33639248 ] || break
    method=$(le_int "$d/cd" $(( co + 10 )) 2); fnl=$(le_int "$d/cd" $(( co + 28 )) 2)
    exl=$(le_int "$d/cd" $(( co + 30 )) 2); cml=$(le_int "$d/cd" $(( co + 32 )) 2); lho=$(le_int "$d/cd" $(( co + 42 )) 4)
    name=$(dd if="$d/cd" bs=1 skip=$(( co + 46 )) count="$fnl" 2>/dev/null)
    if [ "$name" = "payload.bin" ]; then [ "$method" = 0 ] || { echo "payload.bin compressed" >&2; exit 1; }; pay_lho=$lho; break; fi
    co=$(( co + 46 + fnl + exl + cml ))
  done
  [ -n "$pay_lho" ] || { echo "payload.bin not found" >&2; exit 1; }
  rget "$pay_lho" 30 "$d/lh"; local lfn lex PAY; lfn=$(le_int "$d/lh" 26 2); lex=$(le_int "$d/lh" 28 2)
  PAY=$(( pay_lho + 30 + lfn + lex ))
  rget "$PAY" 24 "$d/ph"; [ "$(dd if="$d/ph" bs=1 count=4 2>/dev/null)" = "CrAU" ] || { echo "bad payload magic" >&2; exit 1; }
  local ver msize sig2 DATABASE; ver=$(be_int "$d/ph" 4 8); msize=$(be_int "$d/ph" 12 8)
  sig2=0; [ "$ver" -ge 2 ] && sig2=$(be_int "$d/ph" 20 4)
  rget $(( PAY + 24 )) "$msize" "$d/man"; DATABASE=$(( PAY + 24 + msize + sig2 ))
  local BLOCK=4096 pu_off=-1 pu_len=0 mo=0 tag fn wt ln cs t0 nl nm
  while [ "$mo" -lt "$msize" ]; do
    vfile "$d/man" "$mo"; tag=$VV; mo=$VN; fn=$(( tag >> 3 )); wt=$(( tag & 7 ))
    case "$wt" in
      0) vfile "$d/man" "$mo"; [ "$fn" = 3 ] && BLOCK=$VV; mo=$VN;;
      1) mo=$(( mo + 8 ));;
      5) mo=$(( mo + 4 ));;
      2) vfile "$d/man" "$mo"; ln=$VV; cs=$VN
         if [ "$fn" = 13 ]; then t0=$(le_int "$d/man" "$cs" 1)
           if [ "$t0" = 10 ]; then nl=$(le_int "$d/man" $(( cs + 1 )) 1); nm=$(dd if="$d/man" bs=1 skip=$(( cs + 2 )) count="$nl" 2>/dev/null)
             if [ "$nm" = "$PART" ]; then pu_off=$cs; pu_len=$ln; break; fi; fi; fi
         mo=$(( cs + ln ));;
    esac
  done
  [ "$pu_off" -ge 0 ] || { echo "$PART not in OTA manifest" >&2; exit 1; }
  dd if="$d/man" bs=1 skip="$pu_off" count="$pu_len" 2>/dev/null > "$d/pu"
  local PH plen PSIZE=0 PHASH='' i=0; PH=$(od -An -tx1 -v "$d/pu" | tr -d ' \n'); plen=$(( ${#PH} / 2 ))
  local -a OPS=()
  while [ "$i" -lt "$plen" ]; do
    vhex "$PH" "$i"; tag=$VV; i=$VN; fn=$(( tag >> 3 )); wt=$(( tag & 7 ))
    if [ "$wt" = 0 ]; then vhex "$PH" "$i"; i=$VN
    elif [ "$wt" = 2 ]; then vhex "$PH" "$i"; ln=$VV; local st=$VN
      if [ "$fn" = 7 ]; then local j=$st e=$(( st + ln )) it ifn iwt hl hs
        while [ "$j" -lt "$e" ]; do vhex "$PH" "$j"; it=$VV; j=$VN; ifn=$(( it >> 3 )); iwt=$(( it & 7 ))
          if [ "$iwt" = 0 ]; then vhex "$PH" "$j"; [ "$ifn" = 1 ] && PSIZE=$VV; j=$VN
          elif [ "$iwt" = 2 ]; then vhex "$PH" "$j"; hl=$VV; hs=$VN; [ "$ifn" = 2 ] && PHASH=${PH:hs*2:hl*2}; j=$(( hs + hl )); fi; done
      elif [ "$fn" = 8 ]; then OPS+=( "$st:$ln" ); fi
      i=$(( st + ln ))
    elif [ "$wt" = 1 ]; then i=$(( i + 8 )); elif [ "$wt" = 5 ]; then i=$(( i + 4 )); fi
  done
  truncate -s "$PSIZE" "$OUTF"; local fetched=0 spec st e otype doff dlen j t ofn owt xl xs sb nb k ke et efn dpos ex
  for spec in "${OPS[@]}"; do
    st=${spec%:*}; e=$(( st + ${spec#*:} )); otype=0; doff=0; dlen=0; local -a EXT=(); j=$st
    while [ "$j" -lt "$e" ]; do
      vhex "$PH" "$j"; t=$VV; j=$VN; ofn=$(( t >> 3 )); owt=$(( t & 7 ))
      if [ "$owt" = 0 ]; then vhex "$PH" "$j"; case "$ofn" in 1) otype=$VV;; 2) doff=$VV;; 3) dlen=$VV;; esac; j=$VN
      elif [ "$owt" = 2 ]; then vhex "$PH" "$j"; xl=$VV; xs=$VN
        if [ "$ofn" = 6 ]; then sb=0; nb=0; k=$xs; ke=$(( xs + xl ))
          while [ "$k" -lt "$ke" ]; do vhex "$PH" "$k"; et=$VV; k=$VN; efn=$(( et >> 3 )); vhex "$PH" "$k"; [ "$efn" = 1 ] && sb=$VV; [ "$efn" = 2 ] && nb=$VV; k=$VN; done
          EXT+=( "$sb:$nb" ); fi
        j=$(( xs + xl ))
      elif [ "$owt" = 1 ]; then j=$(( j + 8 )); elif [ "$owt" = 5 ]; then j=$(( j + 4 )); fi
    done
    if [ "$otype" = 6 ] || [ "$otype" = 7 ]; then continue; fi
    rget $(( DATABASE + doff )) "$dlen" "$d/blob"; fetched=$(( fetched + dlen ))
    case "$otype" in 0) cp "$d/blob" "$d/dec";; 8) xz -dc "$d/blob" > "$d/dec";; 1) bzip2 -dc "$d/blob" > "$d/dec";; *) echo "op type $otype needs a source (not a full OTA?)" >&2; exit 1;; esac
    dpos=0; for ex in "${EXT[@]}"; do sb=${ex%:*}; nb=${ex#*:}; dd if="$d/dec" bs="$BLOCK" skip="$dpos" count="$nb" of="$OUTF" seek="$sb" conv=notrunc 2>/dev/null; dpos=$(( dpos + nb )); done
  done
  local got; got=$(sha256sum "$OUTF" | cut -d' ' -f1)
  if [ -n "$PHASH" ] && [ "$got" != "$PHASH" ]; then echo "stock $PART sha256 mismatch vs OTA manifest" >&2; exit 1; fi
  echo "  stock vendor_boot: $(stat -c%s "$OUTF") bytes, fetched $(( fetched / 1048576 )) MiB, sha256 OK"
}

# ---- step 4: graft OrangeFox's recovery onto yogi's own first-stage ----
assemble(){
  local OF_VB=$1 STOCK_VB=$2 OUTF=$3 d="$W/a"; mkdir -p "$d/stock" "$d/of"
  cp "$STOCK_VB" "$d/stock/vb.img"; ( cd "$d/stock" && mb unpack vb.img )
  [ -f "$d/stock/vendor_ramdisk/ramdisk.cpio" ] || { echo "stock unpack failed" >&2; exit 1; }
  cp "$OF_VB" "$d/of/vb.img"; ( cd "$d/of" && mb unpack vb.img )
  [ -f "$d/of/vendor_ramdisk/recovery.cpio" ] || { echo "OrangeFox unpack failed (raw image not a two-fragment vendor_boot?)" >&2; exit 1; }
  local RC="$d/of/vendor_ramdisk/ramdisk.cpio" line p; cp "$d/stock/vendor_ramdisk/ramdisk.cpio" "$RC"
  local -a cmds=( "rm -r system/lib64" "rm -r res" )
  while IFS= read -r line; do [ "${line:0:1}" = "-" ] || continue; p=$(lspath "$line"); [ "$p" = "system/bin/init" ] || cmds+=( "rm $p" ); done < <("$MB" cpio "$RC" "ls system/bin" 2>/dev/null)
  while IFS= read -r line; do [ "${line:0:1}" = "-" ] || continue; p=$(lspath "$line"); case "$p" in *.xml) ;; *) continue ;; esac
    "$MB" cpio "$RC" "extract $p $d/m.xml" >/dev/null 2>&1 || continue
    [[ "$(<"$d/m.xml")" == *'type="device"'* ]] && cmds+=( "rm $p" ); done < <("$MB" cpio "$RC" "ls system/etc/vintf/manifest" 2>/dev/null)
  mb cpio "$RC" "${cmds[@]}"
  ( cd "$d/of" && mb repack vb.img out.img ); [ -f "$d/of/out.img" ] || { echo "repack failed" >&2; exit 1; }
  cp "$d/of/out.img" "$OUTF"
  local pb rb; pb=$(stat -c%s "$RC"); rb=$(stat -c%s "$d/of/vendor_ramdisk/recovery.cpio")
  mb cpio "$d/of/vendor_ramdisk/recovery.cpio" "exists init.recovery.yogi.rc" || { echo "recovery fragment missing yogi init" >&2; exit 1; }
  echo "  assembled: $(stat -c%s "$OUTF") bytes, recovery-mode ramdisk $(( (pb+rb)/1048576 )) MiB (loads < ~100)"
}

# ---- 1. magiskboot (cached) ----
MB="$CACHE/magiskboot-$ABI"
if [ -x "$MB" ]; then echo "[1/4] magiskboot cached"
else
  APK="$CACHE/Magisk-${MAGISK_VER}.apk"
  [ -f "$APK" ] || { echo "[1/4] downloading Magisk ${MAGISK_VER} ..."; curl -fL# "$MAGISK_URL" -o "$APK"; }
  echo "[1/4] extracting magiskboot ($ABI) ..."
  unzip -o -j "$APK" "lib/$ABI/libmagiskboot.so" -d "$CACHE" >/dev/null
  mv "$CACHE/libmagiskboot.so" "$MB"; chmod +x "$MB"
fi

# ---- 2. raw OrangeFox recovery image ----
if [ -n "$RAW" ]; then echo "[2/4] using local raw image $RAW"
else RAW="$CACHE/OrangeFox-raw.img"; echo "[2/4] downloading raw OrangeFox image ..."; curl -fL# "$RAW_URL" -o "$RAW"; fi

# ---- 3. stock vendor_boot ----
echo "[3/4] fetching this device's stock vendor_boot from its OTA ..."
fetch_stock "$CACHE/stock-vendor_boot.img"

# ---- 4. assemble ----
echo "[4/4] assembling flashable image ..."
assemble "$RAW" "$CACHE/stock-vendor_boot.img" "$OUT"

echo
echo "Done. Flash it (bootloader unlocked) with:"
echo "  fastboot flash vendor_boot $OUT"
