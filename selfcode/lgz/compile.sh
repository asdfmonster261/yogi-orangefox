#!/bin/bash

# Скрипт для быстрой сборки компрессора LGZ для хоста и устройства
# Предполагается запуск из директории device/google/pixels/selfcode/lgz/

# Пытаемся определить корень AOSP, если gettop недоступен
if ! command -v gettop &> /dev/null; then
    # Поднимаемся на 6 уровней вверх от device/google/pixels/selfcode/lgz
    AOSP_ROOT="$(cd ../../../../../ && pwd)"
else
    AOSP_ROOT="$(gettop)"
fi

LGZ_SRC_DIR="$(pwd)"
LZMA_DIR="$AOSP_ROOT/external/lzma/C"
OBJ_DIR="$LGZ_SRC_DIR/.build_objs"

# Исходники LZMA, необходимые для работы Lzma2Enc и Lzma2Dec
LZMA_SRCS="$LZMA_DIR/Alloc.c $LZMA_DIR/LzFind.c $LZMA_DIR/LzmaDec.c $LZMA_DIR/LzmaEnc.c $LZMA_DIR/Lzma2Dec.c $LZMA_DIR/Lzma2Enc.c $LZMA_DIR/CpuArch.c"
COMMON_OPT_FLAGS="-O3 -pipe -fopenmp -flto"
CPU_OPT_FLAGS="-march=native -mtune=native"
LZMA_CFLAGS="-I$LZMA_DIR -D_7ZIP_ST $COMMON_OPT_FLAGS $CPU_OPT_FLAGS"

# Имя твоего C-файла из Canvas
SRC_FILE="$LGZ_SRC_DIR/lgzv3.c"

if [ ! -d "$LZMA_DIR" ]; then
    echo "[!] Ошибка: Директория LZMA SDK не найдена по пути $LZMA_DIR"
    echo "Убедитесь, что скрипт запущен внутри дерева AOSP."
    exit 1
fi

if [ ! -f "$SRC_FILE" ]; then
    echo "[!] Ошибка: Исходный файл $SRC_FILE не найден!"
    exit 1
fi

echo "======================================================"
echo "    Сборка Ультра-компрессора LGZ"
echo "======================================================"

mkdir -p "$OBJ_DIR"

compile_obj_if_needed() {
    local src="$1"
    local obj="$2"

    if [ ! -f "$obj" ] || [ "$src" -nt "$obj" ]; then
        gcc -O3 $LZMA_CFLAGS -c "$src" -o "$obj" || return 1
    fi
    return 0
}

# 1. Сборка для хоста (x86_64)
echo "[LGZ] 1. Компиляция хостового бинарника..."

OBJECTS=()

MAIN_OBJ="$OBJ_DIR/$(basename "$SRC_FILE" .c).o"
compile_obj_if_needed "$SRC_FILE" "$MAIN_OBJ" || exit 1
OBJECTS+=("$MAIN_OBJ")

for src in $LZMA_SRCS; do
    obj="$OBJ_DIR/$(basename "$src" .c).o"
    compile_obj_if_needed "$src" "$obj" || exit 1
    OBJECTS+=("$obj")
done

gcc -O3 $LZMA_CFLAGS -o "$LGZ_SRC_DIR/lgz_host_bin" "${OBJECTS[@]}" 2>&1

if [ $? -eq 0 ]; then
    echo "  [ОК] Собрано: $LGZ_SRC_DIR/lgz_host_bin"
else
    echo "  [ОШИБКА] Сборка для хоста провалилась."
    exit 1
fi

# 2. Кросс-компиляция для устройства (aarch64)
# Проверяем наличие компилятора в системе (Fedora: sudo dnf install gcc-aarch64-linux-gnu)
# echo "[LGZ] 2. Кросс-компиляция бинарника для устройства (arm64)..."
# if command -v aarch64-linux-gnu-gcc &> /dev/null; then
#     # Собираем статически (-static), чтобы бинарь работал в recovery без зависимостей
#     aarch64-linux-gnu-gcc -O3 -static $LZMA_CFLAGS -o "$LGZ_SRC_DIR/lgz_device" "$SRC_FILE" $LZMA_SRCS 2>&1
    
#     if [ $? -eq 0 ]; then
#         # Опционально: ужимаем (strip) бинарник устройства
#         aarch64-linux-gnu-strip "$LGZ_SRC_DIR/lgz_device" 2>/dev/null
#         echo "  [ОК] Собрано (arm64, static): $LGZ_SRC_DIR/lgz_device"
#     else
#         echo "  [ОШИБКА] Кросс-компиляция провалилась."
#     fi
# else
#     echo "  [ПРОПУСК] Кросс-компилятор 'aarch64-linux-gnu-gcc' не найден."
#     echo "  Для сборки версии под Android установите его:"
#     echo "  sudo dnf install gcc-aarch64-linux-gnu"
#     echo "  (Или используйте Android.bp для интеграции в систему сборки AOSP)"
# fi

echo "======================================================"
echo "[LGZ] Завершено!"