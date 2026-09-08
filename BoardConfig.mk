#
# Copyright (C) 2024-2026 The OrangeFox Recovery Project
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

# BoardConfig.mk - Board-level configuration for OrangeFox Recovery.
# Family: malibu (Tensor G6, UFS 3c2d0000): yogi (Pixel 11 Pro Fold) and its Pixel 11
# siblings. DEVICE_BUILD_FLAG is malibu.
#
# Crypto: FBE with wrappedkey_v0 + metadata encryption via Trusty TEE KeyMint
# Boot: Virtual A/B with vendor_boot, GKI kernel

DEVICE_PATH := device/google/pixels

# Allow for building with minimal manifest
ALLOW_MISSING_DEPENDENCIES := true

# A/B
AB_OTA_UPDATER := true
AB_OTA_PARTITIONS += \
    boot \
    init_boot \
    vendor_boot \
    vendor_kernel_boot \
    dtbo \
    vbmeta \
    vbmeta_system \
    vbmeta_vendor \
    system \
    system_ext \
    system_dlkm \
    product \
    vendor \
    vendor_dlkm \
    modem \
    abl \
    bl1 \
    bl2 \
    bl31 \
    gsa \
    gsa_bl1 \
    gcf \
    pbl \
    pvmfw \
    tzsw \
    ldfw

# Architecture
TARGET_ARCH := arm64
TARGET_ARCH_VARIANT := armv8-2a
TARGET_CPU_ABI := arm64-v8a
TARGET_CPU_ABI2 :=
TARGET_CPU_VARIANT := generic
TARGET_CPU_VARIANT_RUNTIME := cortex-a55

TARGET_2ND_ARCH := arm
TARGET_2ND_ARCH_VARIANT := armv8-2a
TARGET_2ND_CPU_ABI := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi
TARGET_2ND_CPU_VARIANT := generic
TARGET_2ND_CPU_VARIANT_RUNTIME := cortex-a75

TARGET_SUPPORTS_64_BIT_APPS := true
TARGET_IS_64_BIT := true

# Board
BOARD_HAS_NO_SELECT_BUTTON := true
BOARD_HAS_LARGE_FILESYSTEM := true

# Bootloader
TARGET_BOOTLOADER_BOARD_NAME := $(DEVICE_BUILD_FLAG)
TARGET_NO_BOOTLOADER := true
TARGET_USES_UEFI := true

# Build Broken
BUILD_BROKEN_DUP_RULES := true
BUILD_BROKEN_ELF_PREBUILT_PRODUCT_COPY_FILES := true
BUILD_BROKEN_MISSING_REQUIRED_MODULES := true

# Debug
TARGET_USES_LOGD := true
TWRP_INCLUDE_LOGCAT := true

# Display
TARGET_SCREEN_DENSITY := 420
TARGET_SCREEN_HEIGHT := 2400
TARGET_SCREEN_WIDTH := 1080

# Kernel
TARGET_NO_KERNEL := true
TARGET_KERNEL_ARCH := arm64
TARGET_KERNEL_HEADER_ARCH := arm64
BOARD_KERNEL_IMAGE_NAME := Image.lz4
BOARD_RAMDISK_USE_LZ4 := true
BOARD_BOOT_HEADER_VERSION := 4
BOARD_KERNEL_PAGESIZE := 2048
BOARD_KERNEL_BASE := 0x1000000
BOARD_KERNEL_OFFSET := 0x00008000
BOARD_RAMDISK_OFFSET := 0x01000000
BOARD_KERNEL_TAGS_OFFSET := 0x00000100

VENDOR_CMDLINE := "spmi_smartdv.load_sequential=1 regmap-goog-spmi.load_sequential=1 max77779_pmic.load_sequential=1 max77779_pmic_spmi.load_sequential=1 max77779_pmic_pinctrl.load_sequential=1 samsung_dma_heap.gcma_skip_heaps=gcma_camera_internal dyndbg=\"func alloc_contig_dump_pages +p\" cma_sysfs.experimental=Y init_on_alloc=0 init_on_free=1 rcupdate.rcu_expedited=1 rcu_nocbs=all rcutree.enable_rcu_lazy swiotlb=noforce disable_dma32=on rodata=on sysctl.kernel.sched_pelt_multiplier=4 arm64.nomops aoc_core.aoc_panic_on_ssr_failure=1 aoc_core.aoc_enable_gsa_boot=1 ufs.async_probe=1 vs_drm.async_probe=1 gs_governor_dsulat.async_probe=1 arm64.nosme kasan=off at24.write_timeout=100 log_buf_len=1024K android_arch_task_struct_size=784 bootconfig"
BOARD_BOOTCONFIG := androidboot.usbcontroller=a210000.dwc3
BOARD_BOOTCONFIG += androidboot.boot_devices=3c2d0000.ufs
BOARD_BOOTCONFIG += androidboot.load_modules_parallel=true

BOARD_MKBOOTIMG_ARGS += --pagesize $(BOARD_KERNEL_PAGESIZE)
BOARD_MKBOOTIMG_ARGS += --header_version $(BOARD_BOOT_HEADER_VERSION)
BOARD_MKBOOTIMG_ARGS += --base $(BOARD_KERNEL_BASE)
BOARD_MKBOOTIMG_ARGS += --kernel_offset $(BOARD_KERNEL_OFFSET)
BOARD_MKBOOTIMG_ARGS += --ramdisk_offset $(BOARD_RAMDISK_OFFSET)
BOARD_MKBOOTIMG_ARGS += --tags_offset $(BOARD_KERNEL_TAGS_OFFSET)
BOARD_MKBOOTIMG_ARGS += --vendor_cmdline $(VENDOR_CMDLINE)

# Partitions - Blocks
BOARD_FLASH_BLOCK_SIZE := 131072

# Partitions - Sizes
BOARD_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_VENDOR_BOOTIMAGE_PARTITION_SIZE := 67108864
BOARD_DTBOIMG_PARTITION_SIZE := 4194304

# Partition - Metadata
BOARD_USES_METADATA_PARTITION := true

# Partition Type
BOARD_SYSTEMIMAGE_PARTITION_TYPE := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE := f2fs

# Partitions - Super/Logical
BOARD_SUPER_PARTITION_SIZE := 8531214336
BOARD_SUPER_PARTITION_GROUPS := google_dynamic_partitions
BOARD_GOOGLE_DYNAMIC_PARTITIONS_PARTITION_LIST := system system_ext product vendor vendor_dlkm
BOARD_GOOGLE_DYNAMIC_PARTITIONS_SIZE := 8527020032

GOOGLE_BOARD_PLATFORMS += $(DEVICE_BUILD_FLAG)
TARGET_BOARD_PLATFORM := $(DEVICE_BUILD_FLAG)
PRODUCT_PLATFORM := $(DEVICE_BUILD_FLAG)
TARGET_BOARD_PLATFORM_GPU := mali-g71
BOARD_VINTF_CHECK := false

# Properties
TARGET_VENDOR_PROP += $(DEVICE_PATH)/prebuilt/vendor.prop
TARGET_RECOVERY_FSTAB := $(DEVICE_PATH)/prebuilt/malibu/recovery.fstab

# Recovery
# malibu panels render the shared ABGR_8888 (DRM_FORMAT_RGBA8888) with red and blue
# swapped (orange shows as blue). RGBX_8888 -> DRM_FORMAT_XBGR8888 puts it in BGR order.
# Verified on yogi; assumed uniform across the malibu family (same DPU) until a sibling
# is tested. Fallback if off on a sibling: BGRA_8888 -> DRM_FORMAT_ARGB8888.
TARGET_RECOVERY_PIXEL_FORMAT := RGBX_8888
TARGET_USERIMAGES_USE_EXT4 := true
TARGET_USERIMAGES_USE_F2FS := true
TARGET_USES_MKE2FS := true
RECOVERY_SDCARD_ON_DATA := true
TARGET_NO_RECOVERY := true
TARGET_RECOVERY_WIPE := $(DEVICE_PATH)/prebuilt/recovery.wipe
BOARD_RECOVERY_SNAPSHOT := false

# SPL
PLATFORM_VERSION := 99.87.36
PLATFORM_VERSION_LAST_STABLE := $(PLATFORM_VERSION)
PLATFORM_SECURITY_PATCH := 2099-12-31
BOOT_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)
VENDOR_SECURITY_PATCH := $(PLATFORM_SECURITY_PATCH)

TW_CUSTOM_CPU_TEMP_PATH := /dev/thermal_cpu

TW_THEME := portrait_hdpi
TW_DEFAULT_LANGUAGE := en
TW_EXTRA_LANGUAGES := true
TW_INPUT_BLACKLIST := "hbtp_vm"
TW_USE_TOOLBOX := true
TW_NO_SCREEN_BLANK := true
TW_NO_LEGACY_PROPS := true
TW_MAX_BRIGHTNESS := 3827
TW_DEFAULT_BRIGHTNESS := 219
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel/brightness"

# yogi shows recovery on the cover panel, whose backlight is panel1-backlight (DSI-2)
# with a 0..16383 scale, so the shared 219 default is ~1% (near black). Point at it
# explicitly and default to a clearly visible level.
TW_MAX_BRIGHTNESS := 16383
TW_DEFAULT_BRIGHTNESS := 8000
TW_BRIGHTNESS_PATH := "/sys/class/backlight/panel1-backlight/brightness"
TW_FRAMERATE := 120

# TWRP Configuration - Excludes
TW_EXCLUDE_APEX := true
TW_EXCLUDE_DEFAULT_USB_INIT := true
TW_EXCLUDE_TWRPAPP := true

# TWRP Configuration - Crypto (FBE metadata decryption via Trusty TEE KeyMint)
TW_INCLUDE_CRYPTO := true
TW_INCLUDE_CRYPTO_FBE := true
TW_INCLUDE_FBE_METADATA_DECRYPT := true
TW_USE_FSCRYPT_POLICY := 2
# OF_SKIP_FBE_DECRYPTION := 1
OF_FORCE_DATA_FORMAT_F2FS := 1

# TWRP Configuration - Includes
TW_INCLUDE_FASTBOOTD := true
TW_INCLUDE_RESETPROP := true
TW_INCLUDE_LIBRESETPROP := true
TW_INCLUDE_REPACKTOOLS := true
TW_INCLUDE_NTFS_3G := true
TW_INCLUDE_FUSE_EXFAT := true
TW_INCLUDE_FUSE_NTFS := true
TW_INCLUDE_LPTOOLS := true

# TWRP Configuration - Vendor Modules (GKI only — monolithic kernels have all drivers built-in)
# ifneq ($(FOX_KERNEL_TYPE),non-gki)
# TW_LOAD_VENDOR_BOOT_MODULES := true
# TW_LOAD_VENDOR_MODULES_EXCLUDE_GKI := true
# endif



# Vendor Boot
BOARD_MOVE_RECOVERY_RESOURCES_TO_VENDOR_BOOT := true
BOARD_INCLUDE_RECOVERY_RAMDISK_IN_VENDOR_BOOT := true

# AVB
BOARD_AVB_ENABLE := true
BOARD_AVB_ROLLBACK_INDEX := 0
BOARD_AVB_MAKE_VBMETA_IMAGE_ARGS += --flags 3
BOARD_AVB_VENDOR_BOOT_KEY_PATH := external/avb/test/data/testkey_rsa4096.pem
BOARD_AVB_VENDOR_BOOT_ALGORITHM := SHA256_RSA4096
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX := 0
BOARD_AVB_VENDOR_BOOT_ROLLBACK_INDEX_LOCATION := 2

# Board Info
TARGET_BOARD_INFO_FILE := $(DEVICE_PATH)/board-info.txt

# Additional flags
SELINUX_IGNORE_NEVERALLOWS := true
BOARD_ROOT_EXTRA_FOLDERS := bluetooth dsp firmware persist
BOARD_SUPPRESS_SECURE_ERASE := true
BOARD_MOVE_GSI_AVB_KEYS_TO_VENDOR_BOOT := true
ENABLE_SCHEDBOOST := true
TW_BATTERY_SYSFS_WAIT_SECONDS := 6
TW_VERSION := LeeGarChat
LC_ALL := C
TARGET_USE_CUSTOM_LUN_FILE_PATH := /config/usb_gadget/g1/functions/mass_storage.0/lun.%d/file

BOARD_RECOVERY_IMAGE_PREPARE = bash $(DEVICE_PATH)/fox_build_callback.sh $(TARGET_RECOVERY_ROOT_OUT) --second-call

# Workaround
TARGET_COPY_OUT_VENDOR := vendor
