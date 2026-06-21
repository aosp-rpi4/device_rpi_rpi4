#!/bin/bash
# Packages all RPi4 boot files after AOSP build
# Run from: ~/android/aosp/

OUT="out/target/product/rpi4"
DEVICE="device/rpi/rpi4"
VENDOR="vendor/rpi-firmware"

echo "[rpi4] Packaging boot partition..."

mkdir -p "$OUT/boot_fat"

# Kernel (RPi bootloader expects kernel8.img for arm64)
cp "$DEVICE/kernel/Image.gz"               "$OUT/boot_fat/kernel8.img"

# DTB
cp "$DEVICE/kernel/bcm2711-rpi-4-b.dtb"   "$OUT/boot_fat/"

# Ramdisk
cp "$OUT/ramdisk.img"                      "$OUT/boot_fat/ramdisk.img"

# RPi bootloader config
cp "$DEVICE/boot/config.txt"               "$OUT/boot_fat/"
cp "$DEVICE/boot/cmdline.txt"              "$OUT/boot_fat/"

# RPi GPU firmware (version-independent of the kernel) — must be cloned separately
if [ -d "$VENDOR/boot" ]; then
    cp "$VENDOR/boot/start4.elf"  "$OUT/boot_fat/"
    cp "$VENDOR/boot/fixup4.dat"  "$OUT/boot_fat/"
    echo "[rpi4] GPU firmware copied."
else
    echo "[rpi4] WARNING: RPi firmware not found at $VENDOR/boot"
    echo "[rpi4] Run: git clone --depth=1 https://github.com/raspberrypi/firmware.git $VENDOR"
fi

# Device tree overlays. CRITICAL: overlays must match the kernel-built base DTB.
# The firmware's prebuilt overlays applied to our custom kernel DTB scramble the
# device tree (SD bound to wrong controller, UART disabled). So prefer the
# KERNEL-built overlays placed at $DEVICE/kernel/overlays/. Populate them with:
#   cp -r kernel/rpi/rpi4/arch/arm64/boot/dts/overlays  device/rpi/rpi4/kernel/
if [ -d "$DEVICE/kernel/overlays" ]; then
    cp -r "$DEVICE/kernel/overlays" "$OUT/boot_fat/"
    echo "[rpi4] Using KERNEL-matched overlays ($DEVICE/kernel/overlays)."
elif [ -d "$VENDOR/boot/overlays" ]; then
    cp -r "$VENDOR/boot/overlays" "$OUT/boot_fat/"
    echo "[rpi4] WARNING: using FIRMWARE overlays — may mismatch the custom kernel DTB."
    echo "[rpi4]          (copy kernel/rpi/rpi4/arch/arm64/boot/dts/overlays -> $DEVICE/kernel/)"
fi

echo "[rpi4] Boot partition contents:"
ls -lh "$OUT/boot_fat/"

echo ""
echo "[rpi4] Done! Boot files are in: $OUT/boot_fat/"
echo "[rpi4] Flash with:"
echo "  sudo mkfs.vfat -F32 /dev/sdX1"
echo "  sudo mount /dev/sdX1 /mnt"
echo "  sudo cp -r $OUT/boot_fat/* /mnt/"
echo "  sudo umount /mnt"
