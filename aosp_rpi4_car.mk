# ===========================================================================
# aosp_rpi4_car — Android Automotive OS (AAOS) product for Raspberry Pi 4.
# Same hardware as aosp_rpi4 (rpi4_common.mk) but with the AUTOMOTIVE base
# (car.mk) instead of the handheld base: brings CarService, the Car launcher,
# Car SystemUI, and PRODUCT_CHARACTERISTICS=automotive (the car UI), plus a
# reference Vehicle HAL (in-memory properties — no real vehicle bus needed).
# Goal: AAOS head unit for Android Auto / CarPlay (Carlinkit) on the Pi 4.
# ===========================================================================

# Automotive (AAOS) product base — CarService, Car launcher, Car SystemUI, etc.
$(call inherit-product, packages/services/Car/car_product/build/car.mk)
# Full handheld system content (fonts.xml, RenderScript librs_jni, webview, …).
# car.mk sits on core_minimal; without this the framework's class-preload dies on
# missing librs_jni.so (RenderScript) / fonts.xml. AAOS's own car_generic_system.mk
# inherits handheld_system.mk for exactly this reason.
$(call inherit-product, $(SRC_TARGET_DIR)/product/handheld_system.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/languages_full.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/core_64_bit.mk)
$(call inherit-product, $(SRC_TARGET_DIR)/product/generic_ramdisk.mk)

# Dalvik/ART heap config for a 2 GB device. Without this the platform ships NO
# dalvik.vm.heap* properties, so ART falls back to tiny defaults and system_server
# (a large-heap process) is capped at ~16 MB: it GC-thrashes and then dies with
# OutOfMemoryError (e.g. BinaryTransparencyService.collectBootIntegrityInfo trying
# to allocate ~1 MB), which trips RescueParty -> reboot loop. The RPi4 4B has 2-8 GB
# RAM, so inherit the standard 2 GB profile (heapsize=512m, heapgrowthlimit=192m).
# See device/rpi/rpi4/README.md Stage F.6.
$(call inherit-product, frameworks/native/build/phone-xhdpi-2048-dalvik-heap.mk)

# Shared RPi4 hardware (kernel, graphics/Mesa, gralloc, audio, stub HALs, VINTF)
$(call inherit-product, device/rpi/rpi4/rpi4_common.mk)

# Product identity
PRODUCT_NAME  := aosp_rpi4_car
PRODUCT_MODEL := Android Automotive on Raspberry Pi 4

# Force the automotive UI/characteristics (car launcher + car layouts).
PRODUCT_CHARACTERISTICS := automotive

# Vehicle HAL: reference AIDL VHAL with in-memory properties. CarService blocks
# on android.hardware.automotive.vehicle.IVehicle/default at boot the same way
# AudioService blocked on the audio HAL — so this is mandatory for AAOS to boot.
PRODUCT_PACKAGES += \
    android.hardware.automotive.vehicle@V4-default-service

# ---------------------------------------------------------------------------
# Disable Headless System User Mode (HSUM) — single-user head unit.
#
# car.mk forces ro.fw.mu.headless_system_user?=true. Under HSUM the system user
# (user 0) is headless and a separate "boot user" must be selected; that boot
# user is normally supplied by the Car User HAL (VHAL INITIAL_USER_INFO). Our
# reference in-memory VHAL doesn't drive that handshake, so on boot
# HsumBootUserInitializer.systemRunning() -> UserManagerService.getBootUser()
# parks system_server's main thread on a CountDownLatch for the full 300s
# BOOT_USER_SET_TIMEOUT, then the partial fallback restarts system_server in a
# ~10-minute loop -> never reaches the Car launcher.
#
# A head unit is single-user, so just turn HSUM off: with this false,
# HsumBootUserInitializer.createInstance() returns null and AAOS boots straight
# to a full user 0 (no boot-user wait). Set on the PRODUCT partition (same list
# car.mk uses) so the hard '=false' overrides car.mk's '?=true' default.
#
# NOTE: HSUM mode is decided when user 0 is first created and persisted in
# /data (UserManagerService.isHeadlessSystemUserMode() = !user0.isFull()), so
# this only takes effect on a /data that was created with the prop already
# false. flash_rpi4.sh reformats /data every flash, so a normal reflash suffices.
PRODUCT_PRODUCT_PROPERTIES += \
    ro.fw.mu.headless_system_user=false

# ---------------------------------------------------------------------------
# Bluetooth — declare CLASSIC only (no BLE), keep BT OFF, no HAL (see Stage F.6).
#
# CarService's CarPerUserServiceImpl.onCreate() UNCONDITIONALLY constructs
# CarBluetoothUserService, whose ctor requireNonNull(getAdapter()). SystemServer
# only starts BluetoothManagerService (which provides that adapter object) when
# FEATURE_BLUETOOTH is declared, so we MUST declare it or CarService NPE-crashes.
#
# This board has no usable BT controller yet (the BCM43455 is on the PL011 UART,
# which we use for the serial console — real BT bring-up needs the console moved
# off ttyAMA0 + hci_uart + firmware; a later stage). So if the BT stack ever
# *starts*, it crashes: with no AIDL HAL it falls back to CreateHidl() which
# hard-asserts ("hci_ != nullptr"); and the stock AIDL HAL
# (android.hardware.bluetooth-service.default) is NO better here — with no
# controller it aborts in AsyncFdWatcher ("FORTIFY: FD_SET: fd -1 < 0"). Either
# way -> SIGABRT -> RescueParty reboot loop. So the strategy is to make sure the
# stack NEVER starts:
#   * classic auto-enable is suppressed by def_bluetooth_on=false (overlay below),
#   * BLE is the other trigger (an app requesting BLE scans, independent of
#     BLUETOOTH_ON), so we DON'T declare FEATURE_BLUETOOTH_LE — well-behaved BLE
#     callers gate on it, so they won't start the stack.
# The classic adapter object still exists (FEATURE_BLUETOOTH), so CarService is
# happy. When BT is properly brought up later, re-add bluetooth_le.xml + the real
# HAL. (Wired AA/CarPlay via the Carlinkit dongle is USB and needs no Bluetooth.)
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml

# Device overlay: default Settings.Global.BLUETOOTH_ON = OFF (see BT note above).
PRODUCT_PACKAGE_OVERLAYS += device/rpi/rpi4/overlay

# CarService needs liblargeparcelablejni (com.android.car.internal.LargeParcelableBase
# -> AidlVehicleStub). In the non-module CarService build the .so is not packaged
# (car-lib declares it as jni_libs but the app pulls car-lib via `libs:`, so it
# does not propagate; the module/apex build gets it from the apex). Install it to
# /system/lib64 so com.android.car can dlopen it — otherwise CarService crash-loops
# with UnsatisfiedLinkError ("liblargeparcelablejni.so not found"). See Stage F.6.
PRODUCT_PACKAGES += liblargeparcelablejni

# Device-local aconfig flag-value overrides (release/). Disables the app-op-backed
# permission flags that the BP4A snapshot ships ENABLED but whose <permission>
# aapt2 doesn't finalize in framework-res, which crash-loops system_server in
# AppOpService.createPermissionAppOpMapping. See release/release_config_map.textproto
# and README Stage F.5/F.6.
PRODUCT_RELEASE_CONFIG_MAPS += \
    $(wildcard device/rpi/rpi4/release/release_config_map.textproto)

# Declare USB host (+ accessory) — the RPi4 is a USB host. Without
# android.hardware.usb.host, UsbManager is null and CarService's USB handler
# crashes (android.car.usb.handler BootUsbScanner: UsbManager.getDeviceList() on
# null), adding to the early crash storm. USB host is also the transport for the
# Carlinkit dongle / wired Android Auto, so we want it declared regardless.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.accessory.xml
