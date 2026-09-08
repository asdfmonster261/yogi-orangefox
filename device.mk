#
# Copyright (C) 2024-2026 The OrangeFox Recovery Project
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

# device.mk — Package list, crypto config, and build props for Tensor-based Pixels.
# Covers malibu (Tensor G6): yogi (Pixel 11 Pro Fold) and its Pixel 11 siblings.
# Custom recovery modules (weaver, storageproxyd, etc.) are built from selfcode/.

LOCAL_PATH := device/google/pixels

# Enable virtual A/B OTA
$(call inherit-product, $(SRC_TARGET_DIR)/product/virtual_ab_ota/compression.mk)

# API & VNDK
PRODUCT_SHIPPING_API_LEVEL := 34
PRODUCT_TARGET_VNDK_VERSION := 34

# Dynamic Partitions
PRODUCT_USE_DYNAMIC_PARTITIONS := true

# Boot control HAL (Pixel-specific implementation)
PRODUCT_PACKAGES += \
    android.hardware.boot@1.2-service-pixel \
    android.hardware.boot@1.2-impl-pixel

# Core packages
PRODUCT_PACKAGES += \
    fastbootd \
    update_engine \
    update_engine_sideload \
    update_verifier

# Vendor services
PRODUCT_PACKAGES += \
    vndservicemanager \
    vndservice \
    bootctl

# Libraries
PRODUCT_PACKAGES += \
    libtrusty \
    libsysutils \
    libhidltransport.vendor

RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libsysutils.so

TARGET_RECOVERY_DEVICE_MODULES += libion
RECOVERY_LIBRARY_SOURCE_FILES += \
    $(TARGET_OUT_SHARED_LIBRARIES)/libion.so

# Crypto: FBE metadata decryption via Trusty TEE KeyMint
PRODUCT_PROPERTY_OVERRIDES += \
    ro.hardware.keystore=trusty \
    ro.hardware.gatekeeper=trusty

# Metadata
BOARD_USES_METADATA_PARTITION := true

# Virtual A/B
ENABLE_VIRTUAL_AB := true

# Build properties: defaults to yogi fingerprint, overridden per-device at runtime by runatboot.sh
PRODUCT_BUILD_PROP_OVERRIDES += \
    BuildDesc="yogi-user 17 CD1A.260714.001.A9 15938155 release-keys" \
    BuildFingerprint=google/yogi/yogi:17/CD1A.260714.001.A9/15938155:user/release-keys \
    DeviceProduct=yogi

PRODUCT_SOONG_NAMESPACES += $(LOCAL_PATH)

# Ramdisk snapshot tool (copies ramdisk state before LGZ decompression)
PRODUCT_PACKAGES += \
    ramdisk_snapshot

# Persistent storage proxy for Trusty TEE RPMB (needed before keymint)
PRODUCT_PACKAGES += \
    recovery_storageproxyd

# A14-native Weaver HAL proxy (talks to Titan M2 via /dev/gsc0 directly)
PRODUCT_PACKAGES += \
    recovery_weaver



# Firstage ramdisk fstab (conf-malibu/f2fs -> fstab.malibu*, Tensor G6, UFS 3c2d0000)
PRODUCT_PACKAGES += fstab.malibu.vendor_ramdisk
PRODUCT_PACKAGES += fstab.malibu-fips.vendor_ramdisk

# service \
# 	strace \

PRODUCT_PACKAGES += \
    linker.vendor_ramdisk \
    resize2fs.vendor_ramdisk \
    resize.f2fs.vendor_ramdisk \
    dump.f2fs.vendor_ramdisk \
    fsck.vendor_ramdisk \
    tune2fs.vendor_ramdisk \
    e2fsck.vendor_ramdisk
