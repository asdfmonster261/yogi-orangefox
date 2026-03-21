#!/bin/bash

# Configuration
FILE="$1"
COMPRESSLGZ="$2"
TEST_DIR="./test_files"
LGZ_BIN="./lgz_host_bin"
TIME_BIN="/usr/bin/time"

# Check dependencies
if [ ! -f "$FILE" ]; then echo "Error: $FILE not found!"; exit 1; fi
if [ ! -x "$TIME_BIN" ]; then echo "Please install 'time' package (sudo dnf install time)"; exit 1; fi

# Create test directory if not exists
mkdir -p "$TEST_DIR"

ORIG_SIZE=$(stat -c%s "$FILE")
ORIG_KB=$(awk "BEGIN {printf \"%.2f\", $ORIG_SIZE/1024}")
BASE_NAME=$(basename "$FILE")

echo "========================================================================"
echo "    TARGET: $FILE ($ORIG_KB KB)"
echo "    OUTPUT DIRECTORY: $TEST_DIR"
echo "========================================================================"
echo "Running tests... this may take a while."

RESULTS=()

run_bench() {
    local name="$1"
    local comp_cmd="$2"
    local decomp_cmd="$3"
    local out_file="$4"
    local dec_file="${out_file}.dec"

    # Check if command binary exists (skip shell control-flow words and known wrappers)
    local cmd_bin
    cmd_bin=$(echo "$comp_cmd" | awk '{print $1}')
    # { and ( are shell grouping operators, always valid — do not try command -v on them
    if [[ "$cmd_bin" != "cp" && "$cmd_bin" != "cd" && "$cmd_bin" != "{" && "$cmd_bin" != "(" && "$cmd_bin" != "./*" ]] && ! command -v "$cmd_bin" &> /dev/null; then return; fi
    if [[ "$cmd_bin" == "./"* ]] && [ ! -x "$cmd_bin" ]; then return; fi

    # Clean up old files
    rm -rf "$out_file" "$dec_file"

    # 1. COMPRESSION
    local c_raw
    c_raw=$($TIME_BIN -f "%e|%M|%P" sh -c "$comp_cmd" 2>&1 | tail -n 1)
    
    local t_comp_s
    local ram_comp_kb
    local cpu_comp_pct
    t_comp_s=$(echo "$c_raw" | cut -d'|' -f1)
    ram_comp_kb=$(echo "$c_raw" | cut -d'|' -f2)
    cpu_comp_pct=$(echo "$c_raw" | cut -d'|' -f3 | tr -d ' %')

    if [ ! -f "$out_file" ] || [ ! -s "$out_file" ]; then return; fi

    # 2. DECOMPRESSION
    local d_raw
    d_raw=$($TIME_BIN -f "%e|%M" sh -c "$decomp_cmd" 2>&1 | tail -n 1)
    
    local t_dec_s
    local ram_dec_kb
    t_dec_s=$(echo "$d_raw" | cut -d'|' -f1)
    ram_dec_kb=$(echo "$d_raw" | cut -d'|' -f2)

    # Calculations
    local size
    local kb
    local ratio
    local t_comp_ms
    local t_dec_ms
    local ram_c_mb
    local ram_d_mb
    size=$(stat -c%s "$out_file")
    kb=$(awk "BEGIN {printf \"%.2f\", $size/1024}")
    ratio=$(awk "BEGIN {printf \"%.2f\", ($size*100)/$ORIG_SIZE}")
    t_comp_ms=$(awk "BEGIN {printf \"%.0f\", $t_comp_s * 1000}")
    t_dec_ms=$(awk "BEGIN {printf \"%.0f\", $t_dec_s * 1000}")
    ram_c_mb=$(awk "BEGIN {printf \"%.2f\", $ram_comp_kb / 1024}")
    ram_d_mb=$(awk "BEGIN {printf \"%.2f\", $ram_dec_kb / 1024}")

    RESULTS+=("$size|$name|$kb KB|$ratio%|${t_comp_ms}ms|${t_dec_ms}ms|${ram_c_mb}MB|${ram_d_mb}MB|${cpu_comp_pct}%")
    
    # Optional: remove decompressed file to save space, but keep the compressed one
    rm -rf "$dec_file"
}

# --- REGISTERING TESTS ---

# LGZ (Все режимы: 0, 1, 2, 4)
if [[ -x "$LGZ_BIN" ]]; then
    for lvl in 0 1 2 4; do
        run_bench "LGZ -$lvl" \
            "$LGZ_BIN compress \"$FILE\" \"$TEST_DIR/$BASE_NAME.lvl${lvl}.lgz\" $lvl" \
            "$LGZ_BIN decompress \"$TEST_DIR/$BASE_NAME.lvl${lvl}.lgz\" \"$TEST_DIR/$BASE_NAME.lvl${lvl}.lgz.dec\"" \
            "$TEST_DIR/$BASE_NAME.lvl${lvl}.lgz"
    done
fi

# Brotli
run_bench "Brotli 11" \
    "brotli -q 11 -f $FILE -o $TEST_DIR/$BASE_NAME.br" \
    "brotli -d -f $TEST_DIR/$BASE_NAME.br -o $TEST_DIR/$BASE_NAME.br.dec" \
    "$TEST_DIR/$BASE_NAME.br"

# XZ
run_bench "XZ -9e" \
    "xz -9e -c $FILE > $TEST_DIR/$BASE_NAME.xz" \
    "xz -d -c $TEST_DIR/$BASE_NAME.xz > $TEST_DIR/$BASE_NAME.xz.dec" \
    "$TEST_DIR/$BASE_NAME.xz"

# Bzip3
run_bench "Bzip3" \
    "bzip3 -e -c $FILE > $TEST_DIR/$BASE_NAME.bz3" \
    "bzip3 -d -c $TEST_DIR/$BASE_NAME.bz3 > $TEST_DIR/$BASE_NAME.bz3.dec" \
    "$TEST_DIR/$BASE_NAME.bz3"

# 7z (Note: 7z works better with absolute/specific paths)
run_bench "7z LZMA2" \
    "7z a -m0=lzma2 -mx=9 $TEST_DIR/$BASE_NAME.7z $FILE > /dev/null" \
    "7z x $TEST_DIR/$BASE_NAME.7z -y -o$TEST_DIR/7z_dec_tmp > /dev/null" \
    "$TEST_DIR/$BASE_NAME.7z"

# ZPAQ
run_bench "ZPAQ m5" \
    "zpaq add $TEST_DIR/$BASE_NAME.zpaq $FILE -m5 > /dev/null" \
    "zpaq x $TEST_DIR/$BASE_NAME.zpaq -to $TEST_DIR/$BASE_NAME.zpaq.dec > /dev/null" \
    "$TEST_DIR/$BASE_NAME.zpaq"
# PAQ8PX
# Using a cd/cp wrapper because PAQ8PX stores absolute file paths internally, which can break extraction.
# The archive extension includes the version number (e.g. paq8px213), so detect it at runtime.
if command -v paq8px &> /dev/null; then
    PAQ_BIN=$(command -v paq8px)

    # Detect version from the first line of help output ("paq8px archiver v213 ...")
    PAQ_VER=$("$PAQ_BIN" 2>&1 | head -1 | sed -n 's/.*v\([0-9]\+\).*/\1/p')
    PAQ_EXT="paq8px${PAQ_VER}"

    COMP_CMD="{ set -x; cp \"$FILE\" \"$TEST_DIR/$BASE_NAME\" && cd \"$TEST_DIR\" && \"$PAQ_BIN\" -1 \"$BASE_NAME\"; } > \"$TEST_DIR/paq_comp_debug.log\" 2>&1"
    DECOMP_CMD="{ set -x; cd \"$TEST_DIR\" && \"$PAQ_BIN\" -d \"$BASE_NAME.$PAQ_EXT\" && rm -f \"$BASE_NAME\"; } > \"$TEST_DIR/paq_decomp_debug.log\" 2>&1"

    run_bench "PAQ8PX -1" \
        "$COMP_CMD" \
        "$DECOMP_CMD" \
        "$TEST_DIR/$BASE_NAME.$PAQ_EXT"

    # Проверяем, создался ли файл. Если нет — выводим предупреждение с указанием на лог
    if [ ! -s "$TEST_DIR/$BASE_NAME.$PAQ_EXT" ]; then
        echo -e "\n\e[1;31m[!] ОШИБКА PAQ8PX: Файл не сжат! Проверьте лог: $TEST_DIR/paq_comp_debug.log\e[0m"
    fi
fi


# --- FINAL TABLE ---

printf "\n%-15s | %-12s | %-8s | %-8s | %-8s | %-10s | %-10s | %-8s\n" \
    "Algorithm" "Size (KB)" "Ratio" "Enc Time" "Dec Time" "Enc RAM" "Dec RAM" "Enc CPU"
echo "------------------------------------------------------------------------------------------------"

mapfile -t sorted_results < <(printf '%s\n' "${RESULTS[@]}" | sort -n)

for row in "${sorted_results[@]}"; do
    IFS='|' read -r size name kb ratio t_enc t_dec r_enc r_dec c_enc <<< "$row"
    if [[ "$name" == "LGZ" ]]; then
        printf "\e[1;32m%-15s | %-12s | %-8s | %-8s | %-8s | %-10s | %-10s | %-8s\e[0m\n" "$name" "$kb" "$ratio" "$t_enc" "$t_dec" "$r_enc" "$r_dec" "$c_enc"
    else
        printf "%-15s | %-12s | %-8s | %-8s | %-8s | %-10s | %-10s | %-8s\n" "$name" "$kb" "$ratio" "$t_enc" "$t_dec" "$r_enc" "$r_dec" "$c_enc"
    fi
done
echo "------------------------------------------------------------------------------------------------"