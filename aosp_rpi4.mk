# ===========================================================================
# aosp_rpi4 — HANDHELD AOSP product (phone/tablet UI).
# Hardware config lives in rpi4_common.mk (shared with the automotive variant
# aosp_rpi4_car). This file only sets the handheld base + product identity.
# ===========================================================================

# Handheld AOSP base
$(call inherit-product, $(SRC_TARGET_DIR)/product/aosp_base.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_ramdisk.mk)

# Shared RPi4 hardware (kernel, graphics/Mesa, gralloc, audio, stub HALs, VINTF)
$(call inherit-product, device/rpi/rpi4/rpi4_common.mk)

# Product identity
PRODUCT_NAME  := aosp_rpi4
PRODUCT_MODEL := AOSP on Raspberry Pi 4
