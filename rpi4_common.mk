# ===========================================================================
# RPi4 common device hardware configuration.
# Shared by BOTH products:
#   - aosp_rpi4      (handheld AOSP base: aosp_base.mk)
#   - aosp_rpi4_car  (automotive AAOS base: car.mk)
# This file inherits NO product base and sets NO PRODUCT_NAME — each product
# picks its own base and name and then inherits this for the hardware bits
# (kernel, fstab, graphics/Mesa, gralloc, audio, the stub HALs, VINTF, props).
# ===========================================================================

LOCAL_PATH := device/rpi/rpi4

# Device identity (shared; PRODUCT_NAME + PRODUCT_MODEL are set per-product)
PRODUCT_DEVICE       := rpi4
PRODUCT_BRAND        := Android
PRODUCT_MANUFACTURER := RaspberryPi

# Architecture
TARGET_CPU_ABI   := arm64-v8a
TARGET_CPU_ABI2  :=
TARGET_ARCH      := arm64
TARGET_ARCH_VARIANT := armv8-a

TARGET_2ND_CPU_ABI  := armeabi-v7a
TARGET_2ND_CPU_ABI2 := armeabi

PRODUCT_SHIPPING_API_LEVEL := 34

# Boot image
PRODUCT_COPY_FILES += \
    device/rpi/rpi4/kernel/Image.gz:kernel \
    device/rpi/rpi4/kernel/bcm2711-rpi-4-b.dtb:dtb/bcm2711-rpi-4-b.dtb

# fstab — goes into ramdisk AND vendor
PRODUCT_COPY_FILES += \
    device/rpi/rpi4/ramdisk/fstab.rpi4:$(TARGET_COPY_OUT_RAMDISK)/fstab.rpi4 \
    device/rpi/rpi4/ramdisk/fstab.rpi4:$(TARGET_COPY_OUT_VENDOR)/etc/fstab.rpi4

# init scripts
PRODUCT_COPY_FILES += \
    device/rpi/rpi4/ramdisk/init.rpi4.rc:$(TARGET_COPY_OUT_VENDOR)/etc/init/init.rpi4.rc

# Input device config (IDC) for the USB touch panel — forces touchScreen so taps
# work as direct touch instead of an on-screen pointer. See the .idc for details.
PRODUCT_COPY_FILES += \
    device/rpi/rpi4/idc/Vendor_0483_Product_5750.idc:$(TARGET_COPY_OUT_VENDOR)/usr/idc/Vendor_0483_Product_5750.idc

# Software KeyMint HAL: provides mandatory TEE security level on non-TEE hardware (RPi4 has no ARM TrustZone)
# Correct module name is keymint-service (C++ insecure impl), not keymint-service.software which doesn't exist
PRODUCT_PACKAGES += \
    android.hardware.security.keymint-service

# ---------------------------------------------------------------------------
# Graphics — Mesa3D hardware path (iteration 2). See README "Graphics bring-up".
# Composer (drm_hwcomposer HWC3) + gralloc (minigbm gbm_mesa over Mesa libgbm)
# + GLES (Mesa v3d Gallium) + Vulkan (SwiftShader for now). Each HAL ships its
# own VINTF fragment, so no manifest.xml edits are needed here.
# ---------------------------------------------------------------------------

# Composer: drm_hwcomposer HWC3, drives the vc4 KMS display (/dev/dri/card0).
PRODUCT_PACKAGES += \
    android.hardware.composer.hwc3-service.drm

# Gralloc: minigbm gbm_mesa backend (Mesa libgbm_mesa) — allocates v3d
# (renderD128) buffers that are scanout-shareable with vc4. AIDL gralloc5
# allocator + stable-c mapper.minigbm routed to the gbm_mesa backend.
PRODUCT_PACKAGES += \
    android.hardware.graphics.allocator-service.minigbm \
    mapper.minigbm \
    libgbm_mesa_wrapper

# GLES/EGL: Mesa v3d Gallium — hardware GPU via /dev/dri/renderD128.
PRODUCT_PACKAGES += \
    libEGL_mesa \
    libGLESv1_CM_mesa \
    libGLESv2_mesa \
    libgallium_dri \
    libglapi

# Vulkan via SwiftShader (software) for now; Mesa broadcom (v3dv) later.
PRODUCT_PACKAGES += \
    vulkan.pastel

# Memtrack HAL stub (MemtrackProxyService blocks on it during bootstrap).
PRODUCT_PACKAGES += \
    android.hardware.memtrack-service.example

# Power HAL stub (PowerManagerService blocks on it).
PRODUCT_PACKAGES += \
    android.hardware.power-service.example

# Health HAL stub (BatteryService blocks on it).
PRODUCT_PACKAGES += \
    android.hardware.health-service.example

# Audio HAL (AIDL) — MANDATORY: without it audioserver SIGSEGVs -> no
# IAudioPolicyService -> AudioService blocks system_server main thread -> watchdog.
# AOSP default AIDL audio HAL as the self-contained vendor APEX.
PRODUCT_PACKAGES += \
    com.android.hardware.audio

# Audio policy + effects config (declares primary->default, r_submix AND bluetooth
# modules — one per IModule instance the apex VINTF declares).
PRODUCT_COPY_FILES += \
    device/rpi/rpi4/audio/audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/primary_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/primary_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/r_submix_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/r_submix_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/bluetooth_audio_policy_configuration.xml:$(TARGET_COPY_OUT_VENDOR)/etc/bluetooth_audio_policy_configuration.xml \
    frameworks/av/services/audiopolicy/config/audio_policy_volumes.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_policy_volumes.xml \
    frameworks/av/services/audiopolicy/config/default_volume_tables.xml:$(TARGET_COPY_OUT_VENDOR)/etc/default_volume_tables.xml \
    frameworks/av/services/audiopolicy/config/surround_sound_configuration_5_0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/surround_sound_configuration_5_0.xml \
    hardware/interfaces/audio/aidl/default/audio_effects_config.xml:$(TARGET_COPY_OUT_VENDOR)/etc/audio_effects_config.xml

PRODUCT_VENDOR_PROPERTIES += \
    ro.hardware.egl=mesa \
    ro.hardware.vulkan=pastel \
    debug.hwui.renderer=skiagl

PRODUCT_PROPERTY_OVERRIDES += \
    ro.opengles.version=196608

# Graphics feature permissions (GLES AEP + Vulkan levels)
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.opengles.aep.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.opengles.aep.xml \
    frameworks/native/data/etc/android.software.opengles.deqp.level-2022-03-01.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.software.opengles.deqp.level.xml \
    frameworks/native/data/etc/android.hardware.vulkan.compute-0.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.compute.xml \
    frameworks/native/data/etc/android.hardware.vulkan.level-1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.level.xml \
    frameworks/native/data/etc/android.hardware.vulkan.version-1_1.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.vulkan.version.xml

PRODUCT_OTA_ENFORCE_VINTF_KERNEL_REQUIREMENTS := false
PRODUCT_ENFORCE_VINTF_MANIFEST := true

# Device VINTF files
DEVICE_MANIFEST_FILE                   := device/rpi/rpi4/vintf/manifest.xml
DEVICE_COMPATIBILITY_MATRIX_FILE       := device/rpi/rpi4/vintf/compatibility_matrix.xml
PRODUCT_ENABLE_UFFD_GC := false
