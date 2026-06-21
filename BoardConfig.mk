LOCAL_PATH := device/rpi/rpi4

# Architecture
TARGET_ARCH         := arm64
TARGET_ARCH_VARIANT := armv8-a
TARGET_CPU_ABI      := arm64-v8a
TARGET_CPU_VARIANT  := cortex-a72

# 32-bit secondary arch (required for arm64 builds)
TARGET_2ND_ARCH         := arm
TARGET_2ND_ARCH_VARIANT := armv8-a
TARGET_2ND_CPU_ABI      := armeabi-v7a
TARGET_2ND_CPU_ABI2     := armeabi
TARGET_2ND_CPU_VARIANT  := cortex-a72


# Kernel
TARGET_KERNEL_SOURCE := kernel/rpi/rpi4
TARGET_KERNEL_CONFIG := bcm2711_android_defconfig
TARGET_KERNEL_ARCH   := arm64

# Prebuilt kernel (we built it separately) 
TARGET_PREBUILT_KERNEL      := device/rpi/rpi4/kernel/Image.gz
BOARD_KERNEL_IMAGE_NAME     := Image.gz
BOARD_RAMDISK_USE_LZ4       := true   

# Tell the build system NOT to try building the kernel from source inline
TARGET_NO_KERNEL := false

BOARD_INCLUDE_DTB_IN_BOOTIMG    := true
BOARD_PREBUILT_DTBIMAGE_DIR     := device/rpi/rpi4/kernel
BOARD_DTB_IMAGE_NAME            := bcm2711-rpi-4-b.dtb

# Boot image format
BOARD_BOOT_HEADER_VERSION       := 2
BOARD_MKBOOTIMG_ARGS            := --header_version 2
BOARD_KERNEL_BASE               := 0x00000000
BOARD_KERNEL_PAGESIZE           := 4096
BOARD_RAMDISK_OFFSET            := 0x01000000
BOARD_KERNEL_TAGS_OFFSET        := 0x00000100

# Kernel command line — THIS is what was missing (root= partition)
BOARD_KERNEL_CMDLINE := console=ttyAMA0,115200 \
                        androidboot.hardware=rpi4 \
                        androidboot.selinux=permissive \
                        init=/init \
                        root=/dev/mmcblk0p2 \
                        rootfstype=ext4 \
                        rootwait \
                        ro

# Partitions
BOARD_FLASH_BLOCK_SIZE := 4096
BOARD_BOOTIMAGE_PARTITION_SIZE       := 134217728   # 128M
BOARD_SYSTEMIMAGE_PARTITION_SIZE     := 2147483648  # 2GB
BOARD_VENDORIMAGE_PARTITION_SIZE     := 536870912   # 512MB
BOARD_PRODUCTIMAGE_PARTITION_SIZE    := 536870912   # 512MB
BOARD_SYSTEM_EXTIMAGE_PARTITION_SIZE := 536870912   # 512MB
BOARD_ODMIMAGE_PARTITION_SIZE        := 134217728   # 128MB
BOARD_USERDATAIMAGE_PARTITION_SIZE   := 4294967296  # 4GB
BOARD_CACHEIMAGE_PARTITION_SIZE      := 268435456   # 256MB

# Bootloader
TARGET_NO_BOOTLOADER := true
TARGET_NO_RADIOIMAGE := true

BOARD_SYSTEMIMAGE_FILE_SYSTEM_TYPE  := ext4
BOARD_VENDORIMAGE_FILE_SYSTEM_TYPE  := ext4
TARGET_USERIMAGES_USE_EXT4          := true
TARGET_SUPPORTS_64_BIT_APPS         := true

TARGET_COPY_OUT_VENDOR  := vendor
TARGET_COPY_OUT_PRODUCT := product
TARGET_COPY_OUT_SYSTEM  := system

# Filesystem types for all partitions
BOARD_PRODUCTIMAGE_FILE_SYSTEM_TYPE   := ext4
BOARD_USERDATAIMAGE_FILE_SYSTEM_TYPE  := ext4

# Display
TARGET_SCREEN_DENSITY := 240

# Graphics — Mesa3D hardware path (iteration 2).
#   composer = drm_hwcomposer (vc4 KMS, /dev/dri/card0)
#   GLES/EGL = Mesa v3d Gallium (libEGL_mesa, /dev/dri/renderD128)
#   gralloc  = minigbm gbm_mesa backend over Mesa libgbm_mesa (allocates v3d
#              buffers shareable with vc4 scanout — fixes the cros_gralloc
#              "Failed to initialize driver" dead-end of the minigbm vc4 backend)
#   Vulkan   = SwiftShader (vulkan.pastel) for now; Mesa broadcom (v3dv) later.
#
# Mesa is built from external/mesa3d (android-rpi branch v3d-22.0) via its
# meson wrapper (external/mesa3d/android/Android.mk), gated on these vars:
BOARD_MESA3D_USES_MESON_BUILD := true
BOARD_MESA3D_GALLIUM_DRIVERS  := v3d vc4
# Do NOT build Mesa's libgbm — minigbm already provides libgbm (used by
# drm_hwcomposer); building both collides. The gbm_mesa gralloc backend links
# the *static* libgbm_mesa (from external/mesa3d-v3d/Android.bp) instead.
BOARD_MESA3D_BUILD_LIBGBM     := false
# Vulkan via Mesa broadcom (v3dv) — enable later; SwiftShader covers Vulkan now.
# BOARD_MESA3D_VULKAN_DRIVERS := broadcom

TARGET_USES_VULKAN   := true
TARGET_VULKAN_SUPPORT := true
# SwiftShader needs executable memory (JIT).
PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER := true

# SELinux (start permissive for dev, enforce later)
BOARD_SEPOLICY_DIRS += device/rpi/rpi4/sepolicy
BOARD_USE_ENFORCING_SELINUX := false
