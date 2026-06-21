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
# Declare the Bluetooth hardware feature — required by CarService.
#
# CarService's CarPerUserServiceImpl.onCreate() UNCONDITIONALLY constructs
# CarBluetoothUserService, whose ctor does
#   requireNonNull(getSystemService(BluetoothManager.class).getAdapter(),
#                  "Bluetooth adapter cannot be null")
# There is no feature gate, so a null adapter is fatal -> com.android.car
# crash-loops -> AMS kills it ("crashed too many times") -> CarSystemUI,
# CarLauncher and car.media all NPE because Car never becomes ready (this also
# produced the "shutting down" dialog — Car, not the power policy, was the
# problem; CarPowerManagementService correctly reported state ON).
#
# SystemServer only starts BluetoothManagerService when FEATURE_BLUETOOTH is
# declared (SystemServer.java ~1757); neither handheld_system nor car.mk
# declares it. The RPi4 *does* have onboard Bluetooth (BCM43455 over UART), but
# it isn't wired up yet (no hci_uart/firmware/BT HAL). Declaring the feature is
# enough to make getAdapter() return a (powered-off) non-null adapter, which
# unblocks CarService. Full BT bring-up — needed later for WIRELESS Android Auto
# — is a separate stage; wired AA/CarPlay via the Carlinkit dongle is USB and
# does not need this.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.bluetooth.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth.xml \
    frameworks/native/data/etc/android.hardware.bluetooth_le.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.bluetooth_le.xml

# Declare USB host (+ accessory) — the RPi4 is a USB host. Without
# android.hardware.usb.host, UsbManager is null and CarService's USB handler
# crashes (android.car.usb.handler BootUsbScanner: UsbManager.getDeviceList() on
# null), adding to the early crash storm. USB host is also the transport for the
# Carlinkit dongle / wired Android Auto, so we want it declared regardless.
PRODUCT_COPY_FILES += \
    frameworks/native/data/etc/android.hardware.usb.host.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.host.xml \
    frameworks/native/data/etc/android.hardware.usb.accessory.xml:$(TARGET_COPY_OUT_VENDOR)/etc/permissions/android.hardware.usb.accessory.xml
