# device/rpi/rpi4 — Android Automotive (AAOS) BSP for Raspberry Pi 4

Device tree for running **Android 16 (AOSP, Android Automotive OS)** on the
**Raspberry Pi 4 Model B**, as a car head unit.

**Status:** boots to the **Car Launcher** on Android 16 (`BP4A`, SDK 36) — kernel,
hardware graphics (vc4/v3d Mesa + minigbm gralloc5 + drm_hwcomposer), audio, and
the full AAOS framework come up on the HDMI panel.

> This BSP is intentionally **minimal and device-local**: it sits on a *vanilla*
> AOSP checkout and keeps all board-specific changes inside this repo (plus a few
> forked support repos). The AOSP trees themselves are never patched.

---

## What's in this repo

| Area | Files |
|------|-------|
| Product / board | `aosp_rpi4_car.mk`, `aosp_rpi4.mk`, `rpi4_common.mk`, `AndroidProducts.mk`, `BoardConfig.mk` |
| Kernel + boot | `kernel/` (prebuilt `Image.gz` + dtb + overlays), `boot/`, `ramdisk/`, `mkbootimg.mk`, `rpi4_boot_package.sh` |
| Flashing | `flash_rpi4.sh` (SD-card partition + image flash) |
| Device-local fixes | `overlay/` (RRO/static overlays), `release/` (aconfig flag-value overrides), `sepolicy/`, `vintf/`, `audio/`, `idc/`, `modules/` |
| Boot animation | `build_bootanimation.sh` |

Detailed per-stage bring-up notes (every boot failure and its fix) are kept in a
local `steps.md` (not tracked here) used as source material for a separate
BSP-integration guide.

---

## Getting the full tree (manifest)

This repo is one project in a **`repo` manifest** that overlays a stock AOSP
checkout with the RPi4 device, kernel, and graphics repos. Start there:

### → Manifest repo: **https://github.com/aosp-rpi4/manifest**

It contains `rpi4.xml` and a README with the exact `repo init` / `repo sync` /
`lunch` / build / flash steps. In short:

```bash
repo init -u https://android.googlesource.com/platform/manifest -b <android-16 tag>
# add the RPi4 overlay manifest (see the manifest repo README for the local_manifest step)
repo sync -c -j$(nproc)
source build/envsetup.sh
lunch aosp_rpi4_car-trunk_staging-userdebug
m
sudo ./device/rpi/rpi4/flash_rpi4.sh /dev/sdX     # writes the SD card
```

### Companion repos (github.com/aosp-rpi4)

| Repo | Path | Purpose |
|------|------|---------|
| [`device_rpi_rpi4`](https://github.com/aosp-rpi4/device_rpi_rpi4) | `device/rpi/rpi4` | this device tree |
| [`kernel_rpi_rpi4`](https://github.com/aosp-rpi4/kernel_rpi_rpi4) | `kernel/rpi/rpi4` | RPi4 kernel (6.6.x, Android fragments + EROFS/ashmem) |
| [`external_mesa3d-v3d`](https://github.com/aosp-rpi4/external_mesa3d-v3d) | `external/mesa3d-v3d` | Mesa vc4/v3d Gallium drivers |
| [`external_minigbm`](https://github.com/aosp-rpi4/external_minigbm) | `external/minigbm` | gralloc5 backend with the vc4 backend enabled |

---

## Hardware

- Raspberry Pi 4 Model B (2–8 GB).
- microSD (8 GB+); HDMI on **HDMI0**; USB-C power.
- Serial console: `ttyAMA0` @ 115200 (`picocom -b 115200 /dev/ttyUSB0`).

## Goal & projection note

End target is an AAOS head unit with phone projection. **Android Auto** (receiver)
and **Apple CarPlay** are not in AOSP — on Android head units they're provided by
third-party dongles/apps (e.g. **Carlinkit**) over USB, which is why USB host is
declared here. Plan an integration layer for projection, not a pure-AOSP solution.

## License

Device configuration under Apache-2.0 (see AOSP). Raspberry Pi firmware and kernel
carry their own upstream licenses.
