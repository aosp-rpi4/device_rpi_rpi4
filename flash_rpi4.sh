#!/bin/bash
set -e

# ============================================================
# AOSP RPi4 Flash Script
# Usage: sudo ./flash_rpi4.sh /dev/sdX
# ============================================================

# --- Config ---
AOSP_OUT="/home/mohamed/android/aosp/out/target/product/rpi4"
DEVICE_DIR="/home/mohamed/android/aosp/device/rpi/rpi4"
BOOT_FAT="$AOSP_OUT/boot_fat"
SD_CARD="${1}"
TMPDIR="/tmp/rpi4_flash"

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[FLASH]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $1"; }
die()  { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ============================================================
# Sanity checks
# ============================================================
[ -z "$SD_CARD" ]      && die "Usage: sudo $0 /dev/sdX"
[ "$(id -u)" != "0" ]  && die "Run as root: sudo $0 /dev/sdX"
[ ! -b "$SD_CARD" ]    && die "Device $SD_CARD not found"

# Safety: prevent flashing to root disk
ROOT_DISK=$(lsblk -no PKNAME $(findmnt -n -o SOURCE /) 2>/dev/null | head -1)
if [[ "/dev/$ROOT_DISK" == "$SD_CARD" ]]; then
    die "$SD_CARD is your root disk! Aborting."
fi

# Check required tools
for tool in parted mkfs.vfat mkfs.ext4 dd simg2img partprobe; do
    command -v $tool &>/dev/null || die "Missing tool: $tool (apt install android-tools-fsutils)"
done

# Check boot_fat was packaged
[ ! -d "$BOOT_FAT" ] && die "Boot files not found at $BOOT_FAT — run: bash device/rpi/rpi4/rpi4_boot_package.sh"
[ ! -f "$BOOT_FAT/kernel8.img" ] && die "kernel8.img missing from $BOOT_FAT"
[ ! -f "$BOOT_FAT/ramdisk.img" ] && die "ramdisk.img missing from $BOOT_FAT"
[ ! -f "$BOOT_FAT/start4.elf"  ] && die "start4.elf missing — RPi firmware not copied"

# Check Android images exist
for img in system vendor product; do
    [ ! -f "$AOSP_OUT/${img}.img" ] && die "${img}.img not found in $AOSP_OUT"
done

# ============================================================
log "Target device : $SD_CARD"
log "AOSP output   : $AOSP_OUT"
log "Boot files    : $BOOT_FAT"
echo ""
warn "ALL DATA ON $SD_CARD WILL BE ERASED!"
read -p "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" != "yes" ] && die "Aborted."

# ============================================================
# Unmount all partitions on the card
# ============================================================
log "Unmounting partitions on $SD_CARD..."
umount ${SD_CARD}* 2>/dev/null || true
sleep 1

# ============================================================
# Partition layout
# ============================================================
# p1: boot     FAT32   64MB   RPi firmware + kernel + DTB + ramdisk
# p2: system   ext4    2GB    Android /system
# p3: vendor   ext4    512MB  Android /vendor
# p4: extended          ---   Container for logical partitions
# p5: product  ext4    512MB  Android /product
# p6: userdata ext4    rest   Android /data

log "Partitioning $SD_CARD..."
parted -s "$SD_CARD" mklabel msdos
parted -s "$SD_CARD" mkpart primary fat32    1MiB    65MiB
parted -s "$SD_CARD" mkpart primary ext4     65MiB   2113MiB
parted -s "$SD_CARD" mkpart primary ext4     2113MiB 2625MiB
parted -s "$SD_CARD" mkpart extended         2625MiB 100%
parted -s "$SD_CARD" mkpart logical  ext4    2626MiB 3138MiB
parted -s "$SD_CARD" mkpart logical  ext4    3139MiB 100%
parted -s "$SD_CARD" set 1 boot on

sleep 2
partprobe "$SD_CARD"
sleep 2

# Detect partition naming (sdX1 vs mmcblkXp1)
if [[ "$SD_CARD" == *"mmcblk"* ]]; then
    PART="${SD_CARD}p"
else
    PART="${SD_CARD}"
fi

log "Partition layout:"
lsblk "$SD_CARD"

# ============================================================
# Format partitions
# ============================================================
log "Formatting partitions..."
mkfs.vfat -F 32 -n "BOOT"     ${PART}1
mkfs.ext4 -F   -L "system"    ${PART}2
mkfs.ext4 -F   -L "vendor"    ${PART}3
mkfs.ext4 -F   -L "product"   ${PART}5
mkfs.ext4 -F   -L "userdata"  ${PART}6
log "Formatting done ✓"

# ============================================================
# Flash boot partition (FAT32)
# ============================================================
log "Writing boot partition (FAT32)..."
mkdir -p /mnt/rpi4_boot
mount ${PART}1 /mnt/rpi4_boot
cp -r "$BOOT_FAT"/. /mnt/rpi4_boot/
sync
umount /mnt/rpi4_boot
rmdir  /mnt/rpi4_boot
log "  Boot partition done ✓"
log "  Contents flashed:"
ls -lh "$BOOT_FAT/"

# ============================================================
# Convert sparse images to raw and flash
# ============================================================
mkdir -p "$TMPDIR"

flash_partition() {
    local name=$1
    local part=$2
    local src="$AOSP_OUT/${name}.img"
    local raw="$TMPDIR/${name}.raw"

    log "Converting ${name}.img (sparse → raw)..."
    # Check if sparse or already raw
    if file "$src" | grep -q "Android sparse image"; then
        simg2img "$src" "$raw"
    else
        log "  (already raw format, copying directly)"
        raw="$src"
    fi

    log "Flashing ${name}.raw → ${part}..."
    dd if="$raw" of="$part" bs=4M status=progress conv=fsync
    log "  ${name} done ✓"

    # Cleanup converted file (not if we used src directly)
    [ "$raw" != "$src" ] && rm -f "$raw"
}

flash_partition "system"  "${PART}2"
flash_partition "vendor"  "${PART}3"
flash_partition "product" "${PART}5"

# Userdata left blank — Android formats it on first boot
log "Userdata partition ready (Android initializes on first boot)"

# ============================================================
# Final sync and cleanup
# ============================================================
sync
rm -rf "$TMPDIR"

echo ""
log "============================================"
log " Flash complete!"
log "============================================"
log ""
log " Hardware checklist:"
log "   1. Insert SD card into RPi4"
log "   2. Connect HDMI to HDMI0 (port closest to USB-C power)"
log "   3. Power on RPi4"
log ""
log " Monitor boot via serial:"
log "   picocom -b 115200 /dev/ttyUSB0"
log ""
log " Connect ADB (after Android boots):"
log "   adb connect <rpi4-ip>:5555"
log "   adb -s <rpi4-ip>:5555 shell"
log ""
log " Verify boot:"
log "   adb shell getprop ro.product.device"
log "   adb shell getprop ro.build.version.release"
log "   adb shell getprop sys.boot_completed"
log "============================================"
