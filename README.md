# Android 16 BSP for Raspberry Pi 4 Model B

This document tracks the full integration of Raspberry Pi 4 into AOSP Android 16.
It covers what has been done, why each piece exists, and what still needs to be built.

---

## Project Goal

End target: **Android Automotive OS (AAOS)** running on the RPi4 as a head unit,
with phone projection (**Android Auto** and **Apple CarPlay**).

Staging:
1. Get base `aosp_rpi4` booting to the launcher (current focus — blocked on graphics).
2. Migrate the product to the **automotive** config (`packages/services/Car`,
   car UI / CarService, automotive `PRODUCT_PACKAGES`).
3. Phone projection.

> **Reality check on projection:** neither Android Auto (phone-projection
> *receiver*) nor Apple CarPlay ships in AOSP. AAOS itself is buildable from
> AOSP, but the AA receiver is a proprietary Google component, and CarPlay
> requires Apple MFi licensing — on Android head units it is normally provided
> by third-party apps/dongles (Carlinkit, ZLink, etc.). Plan for an integration
> layer there, not a pure-AOSP solution.

---

## Changelog — boot bring-up (Android 16 / kernel 6.6.78)

Most recent first. Each entry is a fix that moved the boot further.

- **Stage F — Android Automotive (AAOS) product variant.** With the handheld
  platform fully booting, added a second product for the project's actual goal (an
  AAOS head unit). Refactored the device hardware config (kernel, Mesa graphics,
  gralloc, audio, stub HALs, VINTF, props) into a shared `rpi4_common.mk` inherited
  by BOTH products, so the handheld build is unchanged:
  - `aosp_rpi4.mk` — handheld base (`aosp_base.mk`), unchanged behaviour.
  - `aosp_rpi4_car.mk` — automotive base (`packages/services/Car/car_product/build/
    car.mk` → CarService + Car launcher + Car SystemUI), `PRODUCT_CHARACTERISTICS
    := automotive`, plus the reference Vehicle HAL
    `android.hardware.automotive.vehicle@V4-default-service` (in-memory props, no
    real vehicle bus). Registered both in `AndroidProducts.mk`
    (`lunch aosp_rpi4_car-…`). Expect AAOS first boot to need iteration (CarService
    blocks on VHAL / likely the AudioControl HAL, car sepolicy) — same playbook as
    the platform bring-up.
  - **Stage F.1 — AAOS first boot: zygote dies preloading RenderScript.** First car
    boot crash-loops: `RenderScript_jni: dlopen failed: library "librs_jni.so" not
    found` → `Zygote: Error preloading android.renderscript.Element$DataType` →
    `System zygote died` (also `SystemFonts: /system/etc/fonts.xml ENOENT`). VHAL +
    audio HAL were fine. Cause: `car.mk` sits on `core_minimal` — a product *layer*,
    not a full system — so the car system image lacked `librs_jni.so` + `fonts.xml`
    (both come from `handheld_system.mk`, which the handheld product has). The
    framework's class-preload loads RenderScript regardless, so its missing JNI lib
    is fatal. Fix: add `$(call inherit-product, .../product/handheld_system.mk)` to
    `aosp_rpi4_car.mk` (AAOS's own `car_generic_system.mk` inherits it too). Rebuild
    car system → reflash.
  - **Stage F.2 — AAOS: CarService aborts on SELinux — /product not first_stage_mount.**
    Past RenderScript, boot reaches `boot_progress_ams_ready`, dexopt completes, but
    `com.android.car` fatally aborts: `JNI FatalError … selinux_android_setcontext(
    …, "com.android.car") failed` → CarService crash-loops, boot never completes.
    Cause: `car.mk` puts the car policy (the `carservice_app` domain that
    `com.android.car` maps to, via PRODUCT_PRIVATE_SEPOLICY_DIRS) on the **product**
    partition (`/product/etc/selinux/product_sepolicy.cil`). SELinux split policy is
    loaded in **first-stage init**, but `fstab.rpi4` had `/product` as plain `wait`
    (second-stage) — so the car policy never loaded → `carservice_app` is an invalid
    context → setcontext aborts. Fix: mark `/product` **`first_stage_mount`** in
    `ramdisk/fstab.rpi4` (like /system, /vendor). Rebuild ramdisk → reflash boot
    (the product.img already holds the policy).
  - **Stage F.3 — AAOS: 10-minute system_server restart loop = HSUM boot-user wait.**
    Past the sepolicy fix, the car policy loads and `com.android.car` no longer
    aborts, but the boot still never completes — `boot_progress` shows
    `pms_scan_end` then nothing, and ~10 min later a *fresh* `boot_progress_start`
    (new system_server pid) — an infinite restart loop. `kill -3 <system_server>`
    thread dump: `main` is parked in
    `CountDownLatch.await ← UserManagerService.getBootUser ←
    HsumBootUserInitializer.systemRunning ← AMS.systemReady`. Cause: **Headless
    System User Mode (HSUM)**. `car.mk` forces `ro.fw.mu.headless_system_user=true`;
    under HSUM the system user (0) is headless and a separate *boot user* must be
    selected, normally supplied by the **Car User HAL** (VHAL `INITIAL_USER_INFO`).
    Our in-memory reference VHAL doesn't drive that handshake, so `getBootUser`
    parks system_server's main thread on a latch for the full
    `BOOT_USER_SET_TIMEOUT_MS = 300_000` (5 min), then the partial fallback dies and
    the whole thing restarts. Fix: a head unit is single-user, so **disable HSUM** —
    `PRODUCT_PRODUCT_PROPERTIES += ro.fw.mu.headless_system_user=false` in
    `aosp_rpi4_car.mk` (hard `=false` on the product partition overrides car.mk's
    `?=true` default). With HSUM off, `HsumBootUserInitializer.createInstance()`
    returns null (it early-returns when `!UserManager.isHeadlessSystemUserMode()`),
    no boot-user wait, AAOS boots straight to a full user 0. **Important:** HSUM mode
    is decided when user 0 is first created and persisted in `/data`
    (`isHeadlessSystemUserMode() = !user0.isFull()`), so it only takes effect on a
    `/data` created with the prop already false — `flash_rpi4.sh` reformats `/data`
    every flash, so a normal reflash applies it. Rebuild car product (`m`) → reflash.
    **Confirmed:** `sys.boot_completed=1`, boot reaches `boot_progress_enable_screen`,
    no more restart loop.
  - **Stage F.4 — AAOS: CarService crash-loops on missing Bluetooth adapter.**
    Past HSUM the system boots (`boot_completed=1`) and the screen enables, but a
    "Power off / shutting down" dialog appears and the UI never settles. Logcat:
    `com.android.car` `FATAL EXCEPTION: RuntimeException: Unable to create service
    com.android.car.CarPerUserService: NullPointerException: Bluetooth adapter cannot
    be null` at `CarBluetoothUserService.<init>` ← `CarPerUserServiceImpl.onCreate`.
    `CarPerUserServiceImpl.onCreate()` **unconditionally** constructs
    `CarBluetoothUserService`, whose ctor does
    `requireNonNull(getSystemService(BluetoothManager.class).getAdapter(), …)` — no
    feature gate, so a null adapter is fatal. CarService then crash-loops, AMS kills
    it ("crashed too many times"), and every downstream NPE (`com.android.systemui`
    `registerTaskMonitor()` on null, `CarLauncher` `getCarManager()` on null,
    `car.media`) plus the shutdown dialog is just **Car never becoming ready** — the
    power policy was fine (`system_power_policy_all_on`, state ON). The adapter is
    null because `SystemServer` only starts `BluetoothManagerService` when
    `FEATURE_BLUETOOTH` is declared (`SystemServer.java` ~1757), and neither
    `handheld_system` nor `car.mk` declares it. Fix: copy
    `android.hardware.bluetooth.xml` (+ `_le`) into `/vendor/etc/permissions` from
    `aosp_rpi4_car.mk` → `BluetoothManagerService` starts → `getAdapter()` returns a
    (powered-off) non-null adapter → CarService survives. NOTE: the RPi4 *has*
    onboard BT (BCM43455 over UART) but it isn't wired up yet (no
    hci_uart/firmware/BT HAL); this only provides the adapter object. Full BT
    bring-up is a later stage (needed for *wireless* Android Auto; wired AA/CarPlay
    via Carlinkit is USB). Rebuild car product → reflash. Also declare
    `android.hardware.usb.host` (+ accessory) here: without it `UsbManager` is null
    and `android.car.usb.handler` (BootUsbScanner) crashes — and USB host is the
    Carlinkit/wired-AA transport anyway. **Gotcha (cost us a cycle):** the feature
    XMLs land on `/vendor`, so a `/product`-only or stale reflash leaves them
    missing — symptom: `BluetoothAdapter: Bluetooth service is null`, `Can't find
    service: bluetooth_manager`, CarService crash-loops, and **RescueParty escalates
    to `WARM_REBOOT`** (the "Power off / shutting down" screen is RescueParty, not a
    power-policy shutdown). After flashing, verify on device:
    `ls /vendor/etc/permissions | grep -E 'blue|usb'` and `pm list features | grep
    -E 'blue|usb'` before judging the fix.

- **Stage E.2 — USB touchscreen shows a pointer, taps don't work.** The panel
  (`ByQDtech`, USB VID 0483/PID 5750) is a single-touch ABS digitizer
  (`ABS_X 0..1024`, `ABS_Y 0..600`, `BTN_TOUCH`) but its driver doesn't set
  `INPUT_PROP_DIRECT`, so InputReader classifies it as a touch-PAD → on-screen
  pointer. Fix: IDC `device/rpi/rpi4/idc/Vendor_0483_Product_5750.idc` with
  `touch.deviceType = touchScreen`, copied to `/vendor/usr/idc/` via
  `rpi4_common.mk`. (`/vendor` is plain ext4 ro — no verity — so it can also be
  hot-tested via `mount -o rw,remount /vendor` + push IDC + replug/reboot.)

- **Stage E.1 — display "no signal" after UI = screen-off timeout (NOT a fault).**
  CONFIRMED: `dumpsys display` showed `Display State=OFF`; `input keyevent
  KEYCODE_WAKEUP` restores the picture. Graphics correctly drive 1920x1080@60 from
  EDID. It's just DPMS idle-sleep. Keep awake: `settings put system
  screen_off_timeout 2147483647`; automotive keeps the screen on by default. (The
  earlier "firmware forces 720x576" theory was wrong — the framework sets 1080p
  fine; the panel only blanks on idle.)

- **Stage D.4 — past netd: system_server watchdog-killed, blocked on the audio HAL.**
  With netd up, system_server runs uninterrupted but is killed ~60 s later by its
  own framework **Watchdog** (`system_server_pre_watchdog`). The ANR trace
  (`/data/anr/`) main-thread stack: `AudioService.isVolumeFixed` →
  `getDevicesForAttributes` → `AudioSystem` → **blocking `waitForService<IAudioPolicyService>`**.
  Chain: no audio HAL → `audioserver` SIGSEGVs in `AudioFlinger::onFirstRef` →
  `IAudioPolicyService` never registers → AudioService blocks the **main thread** →
  Watchdog kills system_server. (Boot_progress showed PMS finished in ~1 s, so it was
  NOT slow dexopt.) So the deferred audio HAL became mandatory.
  - **Fix:** ship the AOSP default **AIDL** audio HAL, packaged as the self-contained
    vendor APEX `com.android.hardware.audio` (core + effect services, init rc, vintf
    fragment, effect libs) — `PRODUCT_PACKAGES += com.android.hardware.audio`. Plus
    the framework audio-policy config the AudioPolicyService reads from /vendor/etc:
    the generic set (`audio_policy_configuration_generic.xml` → primary + r_submix
    stub modules, + volumes/default_volume_tables/surround + `audio_effects_config.xml`).
    Mirrors `device/google/cuttlefish`. No real audio HW — stub modules just satisfy
    the framework. Reflash vendor.
    **✅ CONFIRMED: audioserver now STABLE (no SIGSEGV); IAudioPolicyService +
    audio.core.IModule/default,/r_submix + effect.IFactory all registered. Watchdog
    no longer fires; system_server stable with ~159 services up (full framework).**
    Remaining: reach `sys.boot_completed=1`/launcher — appears to be first-boot
    dexopt grinding on the slow SD (`system_server` seen in `D mmc_blk_rw_wait`).

- **Stage D.4b — audio HAL still hangs boot: missing `IModule/bluetooth`.** Audio
  HAL up, but watchdog STILL killed system_server (~60s); ANR main-thread stack:
  `AudioService.<init>` → `isCallScreeningModeSupported` →
  `waitForService<IAudioPolicyService>`. Root cause: the audio apex's VINTF fragment
  declares **three** `audio.core.IModule` instances — `default`, `r_submix`,
  **`bluetooth`** — and the framework opens ALL declared instances. The AIDL HAL
  registers one IModule per `<module>` in `/vendor/etc/audio_policy_configuration.xml`
  (the converter maps legacy `primary`→`default`; Module.cpp types: default/r_submix/
  stub/usb/bluetooth — note `primary` is NOT a valid type, it only works via that
  remap). My generic config had only primary+r_submix → `IModule/bluetooth` was
  declared-but-never-registered → `AudioPolicyService` blocked in `waitForService`
  → never registered `IAudioPolicyService` → AudioService `<init>` hung → watchdog.
  - **Fix:** device-local `device/rpi/rpi4/audio/audio_policy_configuration.xml` that
    `xi:include`s primary + r_submix + **bluetooth_audio_policy_configuration.xml**
    (the `<module name="bluetooth">` → AIDL `ModuleBluetooth` stub, no real BT), so
    the HAL registers `IModule/bluetooth` and the framework's wait returns. Ship the
    bluetooth config file too. Vendor-only rebuild → reflash vendor.
    **✅✅ CONFIRMED: ALL THREE `IModule/{default,r_submix,bluetooth}` register;
    AudioPolicyService completes; system_server STABLE (no watchdog, zero ANRs);
    Android UI rendered on the HDMI panel via hardware V3D. 🎉 First boot to UI.**

- **Stage E.1 — display drops to "no signal" after UI (HDMI mode).** Boot reaches
  the UI but the panel loses sync. NOT a crash (system_server stable). Cause: the
  Pi **firmware** appends `video=HDMI-A-1:720x576M@50D,margin_*=32` to the kernel
  cmdline (it defaults to PAL 720x576 — firmware isn't reading EDID, note the
  overscan margins), while the kernel vc4-KMS + the framework DO read EDID and use
  1920x1080 → the mid-boot mode switch drops HDMI sync. Fix direction (TBD from the
  device's EDID modes): a consistent `video=HDMI-A-1:<native>@60` in `cmdline.txt`
  and/or `disable_overscan=1` / `hdmi_group`+`hdmi_mode` so firmware + kernel +
  framework all agree on one mode.

- **Stage D.3 — past memtrack: missing power + health HALs, and netd dies on
  modular netfilter.** After memtrack, system_server advanced through
  `startBootstrapServices` and then blocked the same way on the **power HAL**
  (`android.hardware.power.IPower/default` — "trying to start it as a lazy AIDL
  service … unable to"). Simultaneously **netd crash-looped** (`iptables-restore:
  unable to initialize table 'filter'` → `Failed to initialize BandwidthController
  (Operation not permitted)`), and netd's `onrestart restart zygote` reset
  system_server every ~5 s.
  - **Power + health HALs (vendor):** same recipe as memtrack — ship the AOSP
    example stubs `android.hardware.power-service.example` and
    `android.hardware.health-service.example` (PRODUCT_PACKAGES), and remove the
    manual `power`/`health` `<hal>` blocks from `vintf/manifest.xml` (the stubs
    self-declare via their own fragments → avoid `Conflicting FqInstance`). Base
    sepolicy already labels both binaries. health was the next declared-but-missing
    HAL (BatteryService), added pre-emptively.
  - **netd / netfilter (kernel):** `bcm2711_defconfig` ships the whole
    netfilter/iptables/xtables stack as **`=m`** (153 modules); with no module
    loading they're absent, so iptables can't create the `filter`/`mangle`/`raw`/
    `nat` tables and the `-m bpf` match is missing. Added the Android-required set
    as **`=y`** to `bcm2711_android_defconfig` (NETFILTER_XTABLES, IP[6]_NF_*
    tables+targets, NF_CONNTRACK, NF_NAT, and the netd xt matches/targets incl.
    XT_MATCH_BPF, XT_MATCH_OWNER/QUOTA, XT_TARGET_IDLETIMER). Same rule as the
    DDC-I2C fix: no module loading → every needed driver must be `=y`.
  - Reflash BOTH boot (kernel) and vendor (HALs).
  - **Follow-up (Stage D.3b): IPv6 netfilter still absent after the above.** IPv4
    worked (`/proc/net/ip_tables_names` = nat/mangle/raw/filter) but
    `/proc/net/ip6_tables_names` was missing and netd still died on
    `ip6tables-restore: unable to initialize table 'filter'`. Root cause: base
    `bcm2711_defconfig` has **`CONFIG_IPV6=m`**, so `IP6_NF_IPTABLES=y` can't be
    satisfied (built-in can't depend on a module) and `olddefconfig` silently
    dropped it to `=m`. Fix: add **`CONFIG_IPV6=y`** (the `IP6_NF_*=y` were already
    in the fragment). Rebuild kernel → reflash boot. NOTE pending kernel gaps seen
    but not yet fixed: `CONFIG_SUSPEND`/`PM_WAKELOCKS` (the `/sys/power/state`
    "Function not implemented" + `/sys/power/wake_lock` errors) — non-fatal so far.
  - **Follow-up (Stage D.3c): netd then died one step later in XfrmController.**
    With IPv4+IPv6 netfilter working, netd set up all the bandwidth/firewall/tether
    controllers OK, then `Failed to initialize XfrmController (… Could not open
    netlink socket / Protocol not supported, code 93)` and `cannot find interface
    dummy0`. Root cause: `CONFIG_XFRM_USER=m` (the NETLINK_XFRM socket) and
    `CONFIG_DUMMY=m`. Fix: set `=y` — `CONFIG_XFRM_USER`, `XFRM_INTERFACE`,
    `NET_KEY`, `INET_AH/ESP/IPCOMP`, `INET6_AH/ESP/IPCOMP`, `DUMMY`. Rebuild kernel
    → reflash boot. XfrmController is near the END of netd init, so this should let
    netd fully start and stop the zygote-reset loop.
    **✅ CONFIRMED: netd now stays up (stable pid), system_server runs uninterrupted
    (no more 5 s zygote resets). `/proc/net/ip6_tables_names` populated, `dummy0`
    present.** Boot now a steady-state progression through system_server startup
    (not a loop) — pending: reach `sys.boot_completed=1` / UI.

- **Stage D.2 — system_server hangs at MemtrackProxyService: missing memtrack HAL.**
  After ashmem (D.1), `system_server` runs and gets through `startBootstrapServices`
  (Watchdog, Installer, PowerStats, IStats…) then **blocks at `MemtrackProxyService`**:
  `libc: Unable to set property "ctl.interface_start" to
  "aidl/android.hardware.memtrack.IMemtrack/default": PROP_ERROR_HANDLE_CONTROL_MESSAGE`
  + `ServiceManagerCppClient: Waited one second for …IMemtrack/default`. Boot stays
  on the animation; no UI. (The 5 s SIGSEGVs in the crash buffer are just
  `audioserver` — system_server is *blocked*, not crashing.)
  - **Why:** framework `MemtrackProxyService` does a **blocking `waitForService`**
    for `android.hardware.memtrack.IMemtrack/default` during bootstrap; the device
    manifest *declared* memtrack but shipped **no implementation**, so servicemanager
    asks init to start it, init has no such service, and the wait never returns.
  - **Fix:** ship the AOSP default/example HAL (a no-op stub, no driver needed):
    `PRODUCT_PACKAGES += android.hardware.memtrack-service.example` in `aosp_rpi4.mk`.
    It is `vendor:true`, ships its own init `.rc` (`vendor.memtrack-default`) and
    **its own vintf_fragment** (`memtrack-default.xml`) — so the manual memtrack
    `<hal>` block was **removed** from `vintf/manifest.xml` to avoid a duplicate
    `Conflicting FqInstance` (same lesson as the keymint/allocator HALs). Base
    sepolicy already labels the binary
    (`system/sepolicy/vendor/file_contexts` → `hal_memtrack_default_exec`), so no
    device sepolicy change. Rebuild vendor → reflash vendor.

- **Stage D.1 — system_server crash-loop: kernel missing ashmem driver.** With
  graphics fixed, the boot animation renders but never reaches UI. `system_server`
  aborts on its first init step (`SystemServer.run:970`,
  `ApplicationSharedMemory.create`) with
  `java.lang.RuntimeException: Failed to create ashmem: No such file or directory`,
  killing zygote and respawning everything (incl. audioserver — a red herring).
  - **Why:** Android 16's `ApplicationSharedMemory.nativeCreate` calls libcutils
    `ashmem_create_region()`. Mainline kernel 6.6 **removed the ashmem driver**, so
    `/dev/ashmem` doesn't exist. libcutils' memfd fallback needs
    `ro.treble.enabled=true` (ok) **and** `sys.use_memfd=true` (defaults false). Even
    after `setprop sys.use_memfd true`, the memfd path fails its compat probe:
    `ioctl(ASHMEM_GET_SIZE): -1 ... no ashmem-memfd compat support` — this RPi kernel
    has neither the ashmem driver nor the memfd↔ashmem ioctl shim. (Audio is NOT the
    gate — `audioserver` SIGSEGV in `AudioFlinger::onFirstRef` is just collateral
    from the zygote teardown loop.)
  - **Fix:** add the ashmem driver to the kernel. Copied ACK 14.6.1
    `drivers/staging/android/` (ashmem.c/.h, Kconfig, Makefile, uapi/ashmem.h — uses
    `misc_register` + `register_shrinker(.,"android-ashmem")`, both 6.6-compatible,
    no `class_create`), wired `drivers/staging/{Kconfig,Makefile}` (source android
    Kconfig; `obj-$(CONFIG_ASHMEM) += android/`), set `CONFIG_ASHMEM=y` in
    `bcm2711_android_defconfig` (next to the binder configs). `CONFIG_STAGING=y`/
    `CONFIG_SHMEM=y` already present. Rebuild kernel (merge_config) → repackage boot
    → reflash boot FAT (p1) only.

- **Graphics Stage C.5 — THE buffer-import bug: metadata reserved-region fd
  mistaken for a 2nd image plane. ✅ CONFIRMED FIXED — boot animation renders on
  HDMI via hardware V3D.** `mapExternalTextureBuffer` /
  `GaneshBackendTexture` kept aborting `Failed to create a valid texture
  [128,128] isWriteable:1 format:1` even for a trivial linear RGBA buffer — so it
  was never modifier-related.
  - **Why:** Mesa 22's Android EGL import (`platform_android.c
    droid_create_image_from_native_buffer`) tries 3 ways to get buffer info:
    (1) `mapper_metadata_get_buffer_info` via **HIDL `IMapper@4.0`** —
    `IMapper::getService()` returns NULL here because we run **gralloc5 /
    stable-c `mapper.minigbm`** (HIDL @4.0 was dropped at FCM v8, see
    [[rpi4-gralloc-gbm-mesa-aidl]]); (2) legacy CrOS-gralloc HAL perform — absent;
    (3) fallback `native_window_buffer_get_buffer_info`. The fallback set
    `num_planes = handle->numFds`. But cros_gralloc sets `enable_metadata_fd=true`
    (CrosGralloc4Utils), appending a **metadata reserved-region fd** → for
    single-plane RGBA `numFds = num_planes + 1 = 2`. So Mesa passed
    `createImageFromDmaBufs2` a 2-plane request with `fds[1] = -1` → import fails →
    invalid texture → SF SIGABRT.
  - **Fix:** in `external/mesa3d-v3d/.../platform_android.c`, force `num_planes = 1`
    in the non-YUV fallback (plane-0 dma-buf is always `fds[0]`; the trailing fd is
    metadata, not an image plane). Complements Stage C.4: the fallback hardcodes
    `modifier = DRM_FORMAT_MOD_LINEAR`, so it's only correct because we also force
    linear allocation. Rebuild Mesa → reflash vendor.

- **Graphics Stage C.4 — buffer-import interop: force LINEAR gbm_mesa allocation.**
  After the I2C fix, vc4 KMS comes up (HDMI console shows), gralloc allocates, and
  SF reaches `Enter boot animation`. But RenderEngine SIGABRTs:
  `Failed to create a valid texture [128,128] isWriteable:1 format:1` in
  `GaneshBackendTexture` ← `SkiaRenderEngine::mapExternalTextureBuffer`. First seen
  via `Cache::primeShaderCache` (startup shader warm-up); disabling it with
  `setprop service.sf.prime_shader_cache 0` moved the crash to the FIRST real
  composition buffer — proving it's not a primeCache quirk but a fundamental
  buffer-import failure.
  - **Why:** RPi4 is a split-GPU — v3d (render, card1/renderD128) and vc4 (scanout,
    card0) are separate DRM devices. gbm_mesa allocates render targets with a
    tiling **modifier**; Mesa v3d's `eglCreateImageKHR(EGL_NATIVE_BUFFER_ANDROID)`
    can't reconcile that modifier on import, so every `mapExternalTextureBuffer`
    returns an invalid texture and SF aborts.
  - **Fix (attempt):** force `force_linear = true` in
    `gbm_mesa_driver/gbm_mesa_internals.cpp` (`gbm_mesa_bo_create`) → wrapper adds
    `GBM_BO_USE_LINEAR` → buffers are LINEAR (modifier 0): renderable by v3d,
    scannable by vc4, and importable by Mesa EGL without modifier guesswork. Costs
    GPU bandwidth (no tiling); a later optimization can negotiate tiled modifiers.
  - Reflash vendor only (`vendor.img` carries the rebuilt
    `libminigbm_gralloc_gbm_mesa.so`). Boot WITHOUT the prime_shader_cache override —
    if linear fixes the import, primeCache succeeds too.

- **Graphics Stage C.3 — vc4 KMS display: HDMI DDC I2C driver must be built-in.**
  After the sepolicy label, the whole stack RUNS: `RenderEngine: renderer : V3D 4.2,
  version : OpenGL ES 3.1 Mesa 22.0.2` — hardware GLES alive. But SF still
  crash-loops: `GraphicBufferAllocator: Failed to allocate ... -12` →
  `RenderEngine SIGABRT 'output buffer not gpu writeable'`. logcat root cause:
  `minigbm: Found GPU v3d / GPU require KMSRO entry / Unable to find/open /dev/card
  node with KMS capabilities` and `drmhwc: No pipelines available. Creating
  null-display for headless mode`.
  - **Why:** v3d is render-only; it needs vc4's KMS display node to allocate
    scanout buffers (KMSRO). But only `/dev/dri/card0` (=v3d) exists — **no vc4
    display card**. Kernel: `platform gpu: deferred probe pending`,
    `devices_deferred` = `gpu` (the vc4-kms `brcm,bcm2711-vc5` master, at DT `/gpu`).
    All components ARE bound (2×hdmi, 5×pixelvalve, hvs, txp), yet the master
    defers — `vc4_hdmi_bind()` returns `-EPROBE_DEFER` at `vc4_hdmi.c:3858`
    because `of_find_i2c_adapter_by_node(ddc)` is NULL: the HDMI **DDC I2C bus**
    (`i2c@7ef04500`, DT compat `brcm,bcm2711-hdmi-i2c` → driver `I2C_BRCMSTB`)
    had no adapter, because **`CONFIG_I2C_BRCMSTB=m`** and Android here doesn't
    load kernel modules (`init: Unable to open /lib/modules`).
  - **Fix:** `CONFIG_I2C_BCM2835=y` + `CONFIG_I2C_BRCMSTB=y` in
    `bcm2711_android_defconfig`. Rebuild kernel → repackage boot → reflash boot.
  - Lesson: with no module loading, EVERY driver in a probe dependency chain must
    be `=y`. A single `=m` leaf (the DDC I2C) silently stalls the entire vc4 KMS
    master in deferred-probe, which cascades to "no display" + gralloc failure.

- **Graphics Stage C.2 — Mesa EGL works! Composer HAL sepolicy label.**
  After the DRI symlink fix, `MESA-LOADER`/`chooseEglConfig` is gone — Mesa v3d
  EGL initializes. Boot now stalls one step later: SurfaceFlinger waits forever
  on `android.hardware.graphics.composer3.IComposer/default`, and init refuses
  to start the HWC3 service:
  `Could not ctl.interface_start ... /vendor/bin/hw/android.hardware.composer.hwc3-service.drm
  (labeled "u:object_r:vendor_file:s0") has incorrect label or no domain
  transition from u:r:init:s0`.
  - **Cause:** `device/rpi/rpi4/sepolicy/` was referenced by `BoardConfig.mk`
    (`BOARD_SEPOLICY_DIRS`) but **empty**, so the HAL service binaries got the
    generic `vendor_file` label. init won't exec a service with no domain
    transition — **enforced even in permissive mode**.
  - **Fix:** added `device/rpi/rpi4/sepolicy/file_contexts` labeling the two HAL
    binaries with their standard exec types (the `*_exec -> domain` transitions
    are already in system/sepolicy, so labeling alone suffices in permissive):
    - `…/hw/android.hardware.composer.hwc3-service.drm` → `hal_graphics_composer_default_exec`
    - `…/hw/android.hardware.graphics.allocator-service.minigbm` → `hal_graphics_allocator_default_exec`
  - Rebuild `vendor.img` → `simg2img` → raw → reflash p3.

- **Graphics Stage C.1 — first hardware-GPU boot: Mesa DRI megadriver symlinks.**
  First boot of the Mesa stack: kernel brings up `v3d` + `vc4` (`/dev/dri/card0`
  + `renderD128` present), SurfaceFlinger loads `ro.hardware.egl=mesa` and pulls
  in `libEGL_mesa`/`libglapi`/`libdrm` — but then **crash-loops** with
  `SkiaGLRenderEngine::chooseEglConfig: 'no suitable EGLConfig found'`. logcat
  pinned it: `EGL-MAIN: MESA-LOADER: failed to open v3d: dlopen failed: library
  "/vendor/lib64/dri/v3d_dri.so" not found (search paths /vendor/lib64/dri,
  suffix _dri)` → `eglInitialize ... EGL_NOT_INITIALIZED`.
  - **Cause:** Mesa builds one **megadriver** `libgallium_dri.so`; its DRI loader
    `dlopen`s a per-driver `<driver>_dri.so` (here `v3d_dri.so`) which must be a
    symlink → `libgallium_dri.so`. The android-rpi `Android.mk` only created the
    `libgallium_dri.so.0` symlink, not the per-driver ones.
  - **Fix:** in `external/mesa3d-v3d/android/Android.mk` `mesa3d-lib`, append
    `$(d)_dri.so` symlinks for each `BOARD_MESA3D_GALLIUM_DRIVERS` to the
    `libgallium_dri` module's `LOCAL_MODULE_SYMLINKS` → installs `v3d_dri.so`
    + `vc4_dri.so` → `libgallium_dri.so` in `/vendor/lib{,64}/dri/`.
  - **Not the cause** (ruled out via logcat): the gbm_mesa allocator (it's a
    lazy AIDL service, starts when SF binds IAllocator — SF never got that far);
    the permissive SELinux denials on `/dev/dri/*` (allowed); the `audioserver`
    SIGSEGV (no audio HAL — separate, non-blocking).
  - Rebuild `vendor.img`, reflash vendor partition, re-test.

- **Graphics Stage C — HARDWARE path via Mesa v3d (iteration 2). IN PROGRESS.**
  The software stack (iter 1) dead-ended: stock minigbm's vc4 backend could not
  bind a DRM node (`cros_gralloc: Failed to initialize driver`) — there is no
  v3d backend and vc4 isn't a usable standalone scanout allocator. Fix is to
  bring up real Mesa (v3d/vc4 Gallium) + a gbm_mesa gralloc backend. Reference:
  the working **raspberry-vanilla** tree at `/home/mohamed/android/raspi`
  (Android 14) — same board, proven Mesa+gbm_mesa wiring; ported here to A16.
  - **Mesa source:** `external/mesa3d-v3d/` (android-rpi `external_mesa3d`,
    branch `v3d-22.0`). Kept at a **separate path** — NOT `external/mesa3d` —
    because in Android 16 `external/mesa3d` *is* the gfxstream Mesa and
    `hardware/google/gfxstream/guest/*` depends on gfxstream-guest sources that
    live inside it (`mesa_platform_virtgpu_defaults` etc.). Wholesale-replacing
    it (the android-rpi/raspberry-vanilla model) deletes that source and breaks
    the gfxstream build. Coexistence works: no module-name collisions between
    stock gfxstream Mesa and the v3d Mesa (verified).
  - **Build mechanism:** the meson wrapper `external/mesa3d-v3d/android/Android.mk`
    (GlobalLogic/Stratiienko), gated on `BOARD_MESA3D_*` in `BoardConfig.mk`
    (`USES_MESON_BUILD`, `GALLIUM_DRIVERS := v3d vc4`, `BUILD_LIBGBM := false`).
    Produces `libgallium_dri`, `libEGL_mesa`, `libGLESv{1_CM,2}_mesa`, `libglapi`.
    Prereqs already present: host `meson` 1.3.1, `external/libdrm/meson.build`.
  - **Android 16 build-system gotchas fixed:**
    - Legacy `Android.mk` in `external/` is **blocked** by Soong
      (`Found blocked Android.mk file`). Allowlisted via
      `vendor/google/build/androidmk/allowlist.txt` (data-driven hook read by
      `build/soong/ui/build/androidmk_denylist.go` — no core-source edit).
      Lists both the Mesa wrapper and `gbm_mesa_driver/Android.mk`.
    - `BOARD_MESA3D_BUILD_LIBGBM := true` collides with minigbm's own `libgbm`
      (drm_hwcomposer links it) → set **false**; gbm_mesa links the *static*
      `libgbm_mesa` instead.
    - Mesa 22.0.2 `unreachable(str)` macro vs Android-16 clang's C23 builtin
      `unreachable()` (`-Werror=macro-redefined`) → pin `libgbm_mesa` to
      `c_std: "gnu17"` in `external/mesa3d-v3d/Android.bp` (also changed it from
      `cc_library_static` → `cc_library` so the wrapper can link it shared).
  - **Gralloc:** ported `external/minigbm/gbm_mesa_driver/` from the raspi tree
    (HIDL allocator@4.0 + mapper@4.0 + `libgbm_mesa_wrapper`). Builds the
    `gbm_mesa` minigbm backend (`-DDRV_EXTERNAL`); patched `external/minigbm/drv.c`
    to route `drv_get_backend()` → `init_external_backend()` under `DRV_EXTERNAL`
    (stock minigbm had no external-backend hook). The required gralloc4 Soong
    defaults (`minigbm_gralloc4_{allocator,common}_defaults`,
    `minigbm_gralloc4_mapper_files`) already exist in our A16 minigbm.
  - **device wiring** (`aosp_rpi4.mk`): replaced the iter-1 ANGLE + stock-minigbm
    allocator with the gbm_mesa allocator/mapper + Mesa GLES;
    `ro.hardware.egl=mesa`. Vulkan still SwiftShader (`vulkan.pastel`) for now
    (Mesa `broadcom`/v3dv deferred — `BOARD_MESA3D_VULKAN_DRIVERS` commented).
  - **Mesa 22.0.2-on-Android-16 toolchain fixes** (clang-r547379 / C23 / libc++20
    / lld) — all in `external/mesa3d-v3d/`:
    - `meson_options.txt`: `platform-sdk-version` `max : 33` → `36` (A16 passes 35).
    - `src/util/u_debug_stack_android.cpp`: rewritten to drop the removed
      `libbacktrace` (`backtrace/Backtrace.h` gone in A16); debug-only no-op.
    - `include/c99_math.h`: don't `#define signbit` on `__BIONIC__` — it clobbered
      libc++ C++20 `<compare>`'s `__math::signbit()` ("expected unqualified-id").
    - `android/mesa3d_cross.mk`: append `-std=gnu17` to the meson **c_args**
      (C only) — Soong's `-std=gnu23` made C23 empty-parens `()` mean `(void)`,
      breaking K&R function pointers (`pipe_loader_sw.c` create_winsys). Also
      append `-Wl,--undefined-version` to link args — new lld defaults to
      `--no-undefined-version` and errored on the gallium version script's
      entry points for drivers we don't build (amdgpu/radeon/nouveau/fd/llvm).
    - **Result:** Mesa builds cleanly, BOTH arches →
      `/vendor/{lib,lib64}/{egl/libEGL_mesa.so,egl/libGLESv*_mesa.so,
      dri/libgallium_dri.so,libglapi.so}`.
  - **Gralloc (gbm_mesa) ported to A16 minigbm internal API** — the raspi
    `gbm_mesa_driver/` was written against A14 minigbm; adapted in our tree:
    - `gbm_mesa_internals.cpp`: added `<functional>`/`<cassert>`; `bo->handles[plane]`
      → `bo->handle` (A16 `struct bo` has one `union bo_handle`, not an array);
      `drv_bo_from_format()` gained a `stride_align` arg (pass 1); `bo_map()`
      dropped its `size_t plane` param.
    - `gbm_mesa_driver.cpp`: `struct backend` dropped `bo_get_map_stride`;
      `name` via a mutable static buffer (avoids `-Wwritable-strings`/`-Wcast-qual`).
    - **minigbm core** (`drv_priv.h` + `drv.c`): re-added the `bo_get_plane_fd`
      backend op (A16 removed it). Essential: gbm_mesa allocates on a separate
      Mesa device and owns its dmabuf fds, so the generic
      `drmPrimeHandleToFD(drv->fd, bo->handle)` path can't export them —
      `drv_bo_get_plane_fd()` now prefers `backend->bo_get_plane_fd` when set.
    - **Result:** allocator@4.0 service, mapper@4.0 impl, `libgbm_mesa_wrapper`
      all build (both arches).
  - **VINTF: HIDL allocator@4.0 is BANNED at A16 (FCM v8)** — `check_vintf`
    failed: `android.hardware.graphics.allocator@4.0::IAllocator/default is
    deprecated ... it should not be served`. The raspi gbm_mesa shipped a HIDL
    allocator@4.0 + mapper@4.0. Fix: use the **AIDL gralloc5** allocator
    (`android.hardware.graphics.allocator-service.minigbm`, IAllocator V2) +
    **stable-c** `mapper.minigbm`. The gbm_mesa backend is frontend-agnostic
    (a drv-level `struct backend`), so both stock gralloc5 modules are routed to
    it by swapping their linked lib `libminigbm_gralloc` → `libminigbm_gralloc_gbm_mesa`
    (`cros_gralloc/{aidl,mapper_stablec}/Android.bp`). The AIDL allocator
    advertises mapper suffix "minigbm" → framework loads our gbm_mesa
    `mapper.minigbm`, keeping allocator/mapper on the same backend. Dropped the
    HIDL @4.0 modules from `aosp_rpi4.mk`. (gbm_mesa_driver/ still defines them
    but they're no longer packaged.)
  - **BUILD + PACKAGE COMPLETE.** Full `m` succeeds (check_vintf passes);
    `rpi4_boot_package.sh` assembled `boot_fat/` with KERNEL-matched overlays.
    Verified in the image: AIDL allocator + `mapper.minigbm` both link
    `libminigbm_gralloc_gbm_mesa`; `libgbm_mesa_wrapper`→`libgbm_mesa`;
    `ro.hardware.egl=mesa`. **Ready to flash + boot-test.**
    - Boot package note: the kernel's `arch/arm64/boot/dts/overlays` is a symlink
      to `arch/arm/boot/dts/overlays`; stage with `cp -rL` (not `-r`) into
      `device/rpi/rpi4/kernel/overlays/` or the package ships a broken symlink and
      falls back to firmware overlays.
    - SELinux is permissive for now, so the gbm_mesa allocator opening
      `/dev/dri/renderD128` (v3d) won't be blocked; add
      hal_graphics_allocator → gpu_device sepolicy before going enforcing.
    - On boot, check: `vendor.graphics.allocator` stays up (no SIGABRT loop);
      `logcat` for `gbm_mesa`/`GBM-MESA-GRALLOC` init; SurfaceFlinger picks
      `EGL_mesa` (`adb shell dumpsys SurfaceFlinger | grep -i gles`).

- **Graphics Stage B — userspace HAL: SOFTWARE stack wired (iteration 1).**
  Decision changed to software-first (skip hardware Mesa for now), keeping the
  BSP minimal (vanilla AOSP + device + kernel + one tracked patch). Stack:
  - **Composer:** `android.hardware.composer.hwc3-service.drm` (drm_hwcomposer,
    HWC3) — drives the vc4 KMS display. Ships its own VINTF + init.rc.
  - **Gralloc:** stock minigbm gralloc5 (`android.hardware.graphics.allocator-service.minigbm`
    + `mapper.minigbm`) with the **vc4 backend** enabled via
    `patches/0001-minigbm-enable-vc4-backend.patch` (adds `-DDRV_VC4` to
    minigbm's `generic_cflags`). Apply before building. (Fully device-local was
    rejected: minigbm's allocator/mapper `.cpp` aren't exported as filegroups,
    so it would require vendoring source.)
  - **GLES:** ANGLE (`libEGL_angle` + `libGLESv1_CM_angle` + `libGLESv2_angle`,
    `ro.hardware.egl=angle`) implemented on top of Vulkan.
  - **Vulkan:** SwiftShader software (`vulkan.pastel`, `ro.hardware.vulkan=pastel`,
    `PRODUCT_REQUIRES_INSECURE_EXECMEM_FOR_SWIFTSHADER`), `TARGET_USES_VULKAN`.
  - `debug.hwui.renderer=skiagl`, `ro.opengles.version=196608`, GLES/Vulkan
    permission XMLs. Template cribbed from
    `device/linaro/dragonboard/shared/graphics/swangle/`.
  - **config.txt:** dropped forced `hdmi_group/hdmi_mode` so vc4 KMS reads EDID
    (forcing 1080p gave "no signal" on the touch panel).
  - Files: `aosp_rpi4.mk` (packages/props/permissions), `BoardConfig.mk`
    (Vulkan flags), `boot/config.txt`, `patches/`, `vintf/manifest.xml`.
  - **VINTF fix:** removed the stale `android.hardware.graphics.allocator`
    placeholder from `vintf/manifest.xml` — the minigbm allocator service now
    ships its own `allocator.xml` fragment, so keeping it caused
    `check_vintf: Conflicting FqInstance: IAllocator/default`. (Same pattern as
    the KeyMint VINTF conflict: don't hand-declare a HAL whose service ships a
    fragment.)
  - Expected: SurfaceFlinger gets gralloc + composer + GLES/Vulkan and stops
    crash-looping → boots to UI on HDMI (software-rendered).
  - **Result (iter 1 boot):** SF SIGABRT crash-loop is GONE — SF stays up,
    loads `vulkan.pastel.so`. New blocker: the minigbm allocator service
    (`vendor.graphics.allocator`) does not register, so SF blocks on
    `IAllocator/default` and servicemanager falls back to a (failing) lazy
    start. Need logcat to see why the allocator/minigbm fails to start. Also
    fixed the build: removed the stale allocator decl from `vintf/manifest.xml`
    (Conflicting FqInstance with the service's own allocator.xml fragment).
  - **Diag:** allocator binary IS installed (`/vendor/bin/hw/…minigbm`, 69 KB),
    but `vendor.graphics.allocator` crashes on init and init stops restarting it
    after 4 crashes (same pattern as `audioserver` SIGSEGV). SF's lazy-start
    can't revive it (stock allocator.rc has no `interface aidl` line). Suspect:
    cros_gralloc can't get a usable DRM node — `renderD128` is **v3d** (no
    minigbm backend) and `card0`/**vc4** display node may not be allocatable by
    the allocator. This is the known minigbm-vc4-on-RPi4 limitation (no v3d
    backend); proper fix is gbm/Mesa, but checking the exact error first.
  - **Confirmed error** (ran the binary by hand): `Minigbm AIDL allocator
    starting up… / Failed to initialize driver / Failed to initialize Minigbm
    AIDL allocator`. i.e. `cros_gralloc_driver::init_try_nodes()` returns NULL —
    no `/dev/dri` node yields a driver. Ruled out: vc4 backend IS compiled
    (`nm vc4.o` shows `backend_vc4`/`vc4_init`); `/dev/dri/*` is `0666 root
    graphics` so not a perms issue. Leading hypothesis: **v3d owns `card0`** (boot
    log: `Initialized v3d … on minor 0`), so there's no `vc4` card node for
    minigbm to bind and it has no v3d backend → dead end without Mesa/GBM. Need
    `grep DRIVER /sys/class/drm/*/device/uevent` to confirm. If so: the software
    path still needs Mesa (GBM allocates via the v3d render node).
  - **CONCLUSION — minigbm gralloc is a dead-end on RPi4.** RPi4 splits GPU
    (v3d, render) and display (vc4, KMS) into separate DRM drivers; buffers must
    be allocated so v3d can render and vc4 can scan them out. That cross-driver
    sharing is exactly what **Mesa's GBM** does; a standalone minigbm can't
    (no v3d backend; vc4 node not a usable unprivileged scanout allocator).
    Therefore **gralloc requires Mesa even with software (SwiftShader)
    rendering.** Decision: pivot to importing Mesa (v3d Gallium + GBM) — this
    fixes gralloc AND gives hardware GL (the original "Mesa v3d" goal). The
    SwiftShader/ANGLE wiring can be removed or kept as a fallback. Next: import a
    Mesa with the meson-Android build (`BOARD_MESA3D_GALLIUM_DRIVERS := v3d vc4`,
    `BOARD_MESA3D_VULKAN_DRIVERS := broadcom`), per the dragonboard template.
- **Graphics Stage B — userspace HAL: investigation + plan.** Decision: full
  HW-accelerated path (Mesa v3d). Findings:
  - **Composer:** `external/drm_hwcomposer` is present and clean — provides
    `android.hardware.composer.hwc3-service.drm` with its own init.rc + VINTF.
  - **Gralloc:** only `external/minigbm` (no gbm/drm_gralloc). cros_gralloc
    opens `renderD128` (v3d) first then `card0` (vc4). minigbm has a `vc4`
    backend but it is gated behind `-DDRV_VC4`, which **no** `platform` soong
    preset defines → needs a minigbm patch (add a `vc4` platform / DRV_VC4).
  - **EGL/GLES — the blocker:** stock `external/mesa3d` (25.0.0-devel) is the
    **gfxstream/emulator** variant; its Android.bp does NOT build the
    `v3d`/`vc4` Gallium drivers, and the meson→Android build glue
    (`BOARD_MESA3D_USES_MESON_BUILD`) is **absent** from this tree (only
    `device/linaro/dragonboard/.../mesa/BoardConfig.mk` *references* it).
    `meson`+`ninja` are on the host. So hardware Mesa requires **importing a
    Mesa tree with the meson-Android `Android.mk` wrapper** (as android-rpi /
    KonstaKANG ship), then setting `BOARD_MESA3D_GALLIUM_DRIVERS := v3d vc4`,
    `BOARD_MESA3D_VULKAN_DRIVERS := broadcom`. Reference template:
    `device/linaro/dragonboard/shared/graphics/{mesa,minigbm_msm}/`.
  - Plan/order: (1) import Mesa+wrapper, (2) minigbm vc4 patch + packages,
    (3) drm_hwcomposer package, (4) BoardConfig/properties/permission-XMLs/VINTF
    per dragonboard template, (5) drop forced `hdmi_mode`, let KMS read EDID.
- **Graphics Stage B — foundation (VERIFIED ✅, kernel #10).** `ls /dev/dri/`
  shows `card0` (vc4 display) + `renderD128` (v3d GPU); dmesg shows
  `vc4-drm gpu: bound ...hvs` and `[drm] Initialized v3d`. Serial + SD intact
  (kernel-matched overlay did NOT scramble the DT). HDMI shows "no signal" —
  expected: nothing does a KMS modeset until SurfaceFlinger has a composer.
  Note: `config.txt` still forces `hdmi_group=1 hdmi_mode=16` → the firmware
  emits `video=HDMI-A-1:1920x1080M@60D`; for the touch panel we should drop the
  forced mode and let KMS read EDID. Next: userspace HAL (minigbm + hwc + Mesa).
- **Graphics Stage B — foundation (applied).** Enabled the
  display/GPU foundation so SurfaceFlinger can get a composer later:
  - `bcm2711_android_defconfig` fragment: `CONFIG_DRM_VC4=y`, `CONFIG_DRM_V3D=y`
    (base has them `=m`), `CONFIG_CMA_SIZE_MBYTES=256`.
  - `boot/config.txt`: `dtoverlay=vc4-kms-v3d,cma-256` + `max_framebuffers=2`.
  - `rpi4_boot_package.sh`: now ships the **kernel-matched** overlays from
    `device/rpi/rpi4/kernel/overlays/` (populate from
    `kernel/rpi/rpi4/arch/arm64/boot/dts/overlays/`), falling back to firmware
    overlays only if absent. Firmware overlays must NOT be used with a custom
    kernel DTB (they scrambled the DT → SD/UART dead — see Troubleshooting).
  - Verify after flashing: serial + SD still work AND `/dev/dri/card0` +
    `/dev/dri/renderD128` exist. Userspace HAL (minigbm/drm_hwcomposer/Mesa)
    comes next.
- **Kernel must be built with `merge_config`** (base `bcm2711_defconfig` +
  `bcm2711_android_defconfig` fragment). Building the fragment alone drops
  `RASPBERRYPI_FIRMWARE`, `CLK_RASPBERRYPI`, `MMC_SDHCI_IPROC`,
  `MMC_BCM2835_*` → **dead serial, dead HDMI, SD not found → first-stage
  reboot loop.** Confirmed cause of a long "nothing on serial/screen" detour.
  See Build Steps §1.
- **`/data` never mounted → cascade of failures.** Two parts:
  (a) fstab mount point must be `/data` (not `/userdata`) so vold/fs_mgr
  recognise the userdata partition; (b) only `/system` + `/vendor` use
  `first_stage_mount`; every other fstab entry needs an explicit `mount_all`.
  Added `on fs / mount_all /vendor/etc/fstab.rpi4` to `ramdisk/init.rpi4.rc`.
  Also dropped `checkpoint=fs` (f2fs-oriented, not needed on ext4).
  This single fix resolved keystore2 SIGABRT (`/data/misc/keystore` was on the
  read-only rootfs) **and** the `reboot,netbpfload-missing` loop (the tethering
  APEX could not decompress to `/data/apex/decompressed` → `bpfloader` stayed
  the `/system/bin/false` placeholder). `netbpfload` now reports `rc:01`.
- **KeyMint HAL.** RPi4 has no TrustZone/TEE, so the mandatory KeyMint security
  level is provided by the C++ insecure impl:
  `PRODUCT_PACKAGES += android.hardware.security.keymint-service`
  (module name is `keymint-service`, *not* `…-service.software`).
- **VINTF conflict.** Removed the keymint/sharedsecret/secureclock HAL entries
  from `vintf/manifest.xml` — the keymint-service binary auto-installs its own
  VINTF fragments via `vintf_fragment_modules`; declaring them twice caused
  `Conflicting FqInstance: ISharedSecret/default`.
- **cgroups + PSI** via `boot/cmdline.txt`: `cgroup_enable=memory
  cgroup_enable=cpuset psi=1` (the RPi firmware appends `cgroup_disable=memory`;
  these re-enable what Android needs).
- **lunch combo:** `aosp_rpi4-trunk_staging-userdebug`.

---

## Repository Layout

```
aosp/
├── device/rpi/rpi4/            ← this BSP (you are here)
│   ├── AndroidProducts.mk      ← registers aosp_rpi4 lunch target
│   ├── BoardConfig.mk          ← hardware constants, partition sizes, kernel path
│   ├── aosp_rpi4.mk            ← product definition (inherits AOSP base)
│   ├── mkbootimg.mk            ← legacy boot image packaging (not the main path)
│   ├── boot/
│   │   ├── config.txt          ← RPi bootloader config (UART, GPU mem, HDMI)
│   │   └── cmdline.txt         ← kernel command line passed by RPi bootloader
│   ├── kernel/
│   │   ├── Image               ← uncompressed kernel (reference copy)
│   │   ├── Image.gz            ← compressed kernel → flashed as kernel8.img
│   │   └── bcm2711-rpi-4-b.dtb ← device tree blob for RPi 4B
│   ├── modules/6.6.78-v8+/    ← pre-built kernel modules (.ko.xz)
│   ├── ramdisk/
│   │   ├── fstab.rpi4          ← partition mount table for first-stage init
│   │   └── init.rpi4.rc        ← device-specific init script
│   ├── vintf/
│   │   ├── manifest.xml        ← HALs this device provides
│   │   └── compatibility_matrix.xml ← HALs this device requires
│   ├── sepolicy/               ← device SELinux policy (TO BE CREATED)
│   ├── rpi4_boot_package.sh    ← packages kernel + ramdisk → out/.../boot_fat/
│   └── README.md               ← this file
│
├── kernel/rpi/rpi4/            ← RPi Linux 6.6.78 kernel source (cloned separately)
│   └── arch/arm64/configs/
│       └── bcm2711_android_defconfig ← the kernel config used for this build
│
├── vendor/rpi-firmware/        ← RPi GPU firmware (cloned separately)
│   └── boot/
│       ├── start4.elf          ← VideoCore firmware
│       ├── fixup4.dat          ← SDRAM split config
│       └── overlays/           ← device tree overlays
│
├── flash_rpi4.sh               ← full SD card flash script (run as root)
└── out/target/product/rpi4/
    ├── boot_fat/               ← assembled FAT boot partition (intermediate)
    ├── system.img              ← Android /system (ext4)
    ├── vendor.img              ← Android /vendor (ext4)
    ├── product.img             ← Android /product (ext4)
    └── userdata.img            ← Android /data (ext4, formatted on first boot)
```

---

## Prerequisites

### Host packages
```bash
sudo apt install -y \
    git curl python3 repo \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
    bc bison flex libssl-dev make \
    android-tools-fsutils simg2img img2simg \
    parted dosfstools e2fsprogs \
    picocom
```

### Clone AOSP (Android 16)
```bash
mkdir ~/android/aosp && cd ~/android/aosp
repo init -u https://android.googlesource.com/platform/manifest -b android-16.0.0_r1
repo sync -c -j$(nproc) --no-tags
```

### Clone RPi kernel source
```bash
cd ~/android/aosp
git clone --depth=1 -b rpi-6.6.y \
    https://github.com/raspberrypi/linux.git \
    kernel/rpi/rpi4
```

### Clone RPi GPU firmware
```bash
cd ~/android/aosp
git clone --depth=1 \
    https://github.com/raspberrypi/firmware.git \
    vendor/rpi-firmware
```

---

## SD Card Partition Layout

| # | Label    | Type  | Size   | Android mount |
|---|----------|-------|--------|---------------|
| 1 | BOOT     | FAT32 | 64 MB  | (bootloader)  |
| 2 | system   | ext4  | 2 GB   | /system       |
| 3 | vendor   | ext4  | 512 MB | /vendor       |
| 4 | extended | —     | rest   | container     |
| 5 | product  | ext4  | 512 MB | /product      |
| 6 | userdata | ext4  | rest   | /data         |

The partition numbers match the block device paths in `ramdisk/fstab.rpi4`
(`mmcblk0p2` = system, `mmcblk0p3` = vendor, etc.).

---

## Build Steps (full from scratch)

### 1. Build the kernel

The android defconfig is a fragment — it adds Android-specific options on top of
the full RPi4 hardware config. You must merge both; running `make bcm2711_android_defconfig`
alone loses critical hardware drivers (PL011 UART, GPU, etc.).

```bash
cd ~/android/aosp/kernel/rpi/rpi4

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-

# Step 1: start from the full RPi4 hardware config
make bcm2711_defconfig

# Step 2: merge Android additions on top (writes back to .config)
scripts/kconfig/merge_config.sh -m .config arch/arm64/configs/bcm2711_android_defconfig

# Step 3: resolve any new symbols introduced by the merge
make olddefconfig

# Step 4: build
make -j$(nproc) Image.gz dtbs
```

Copy outputs into the BSP:
```bash
cd ~/android/aosp
cp kernel/rpi/rpi4/arch/arm64/boot/Image          device/rpi/rpi4/kernel/Image
cp kernel/rpi/rpi4/arch/arm64/boot/Image.gz        device/rpi/rpi4/kernel/Image.gz
cp kernel/rpi/rpi4/arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb \
                                                    device/rpi/rpi4/kernel/bcm2711-rpi-4-b.dtb
```

If you changed any driver that produces a `.ko`, rebuild modules too:
```bash
make -j$(nproc) modules
make INSTALL_MOD_PATH=modules_out modules_install
# then copy updated .ko files into device/rpi/rpi4/modules/
```

### 2. Build AOSP

```bash
cd ~/android/aosp
source build/envsetup.sh
lunch aosp_rpi4-userdebug
make -j$(nproc)
```

This produces `out/target/product/rpi4/{system,vendor,product,userdata}.img`.

### 3. Package the boot partition

```bash
bash device/rpi/rpi4/rpi4_boot_package.sh
```

This assembles `out/target/product/rpi4/boot_fat/` with:
- `kernel8.img` (= Image.gz)
- `bcm2711-rpi-4-b.dtb`
- `ramdisk.img`
- `config.txt`, `cmdline.txt`
- `start4.elf`, `fixup4.dat`, `overlays/` (from vendor/rpi-firmware)

### 4. Flash the SD card

```bash
sudo bash flash_rpi4.sh /dev/sdX   # replace sdX with your card
```

> **Important:** Always re-run step 3 and step 4 together after changing the kernel
> or ramdisk. The SD card is independent from the build output on disk.

---

## Serial Console

Connect a USB-to-TTL adapter to the RPi4 GPIO UART pins:
- Pin 8  (GPIO14) → TX
- Pin 10 (GPIO15) → RX
- Pin 6  (GND)    → GND

Monitor with picocom:
```bash
picocom -b 115200 /dev/ttyUSB0
```

The kernel outputs to `ttyAMA0` (PL011 full UART). `config.txt` has:
```
enable_uart=1
dtoverlay=miniuart-bt    # frees PL011 for console, moves BT to mini-UART
```

---

## Kernel Configuration (`bcm2711_android_defconfig`)

Key options required for Android:

| Config | Value | Why |
|--------|-------|-----|
| `CONFIG_SERIAL_AMBA_PL011` | `y` | `ttyAMA0` serial console driver |
| `CONFIG_SECURITY_SELINUX` | `y` | SELinux compiled in |
| `CONFIG_LSM` | `"capability,audit,selinux"` | activates SELinux at boot |
| `CONFIG_DEFAULT_SECURITY_SELINUX` | `y` | SELinux is the default LSM |
| `CONFIG_AUDIT` | `y` | required by SELinux |
| `CONFIG_ANDROID_BINDER_IPC` | `y` | Binder IPC for Android services |
| `CONFIG_ANDROID_BINDERFS` | `y` | Binder filesystem |
| `CONFIG_DM_VERITY` | `y` | verified boot (dm-verity) — must be built-in |
| `CONFIG_BLK_DEV_DM` | `y` | device-mapper core — **must be built-in (`y`), not module (`m`)** |
| `CONFIG_DM_SNAPSHOT` | `y` | Virtual A/B OTA snapshots — must be built-in |
| `CONFIG_DM_ZERO` | `y` | dm-zero target — must be built-in |
| `CONFIG_DM_WRITECACHE` | `y` | dm-writecache — must be built-in |
| `CONFIG_DM_INTEGRITY` | `y` | dm-integrity — must be built-in |

**Bugs we hit and fixed:**

- `CONFIG_LSM=""` → init aborted with `mount selinuxfs failed: Invalid argument`
  because SELinux was compiled in but not placed in the LSM activation list.
  Fixed to `CONFIG_LSM="capability,audit,selinux"`.

- `CONFIG_SERIAL_AMBA_PL011` unset → completely blank serial terminal after
  a kernel rebuild, because the PL011 driver (`ttyAMA0`) was not compiled in.
  Root cause: `make bcm2711_android_defconfig` alone drops all RPi4 hardware
  drivers. Fixed by adding PL011 explicitly and using the merge build process.

- `CONFIG_DEFAULT_SECURITY_APPARMOR=y` → wrong LSM default for Android.
  Changed to `CONFIG_DEFAULT_SECURITY_SELINUX=y`.

- `CONFIG_BLK_DEV_DM=m` (module) → first-stage init crashes with
  `device-mapper device not found after polling timeout` because device-mapper
  must be available before /system is mounted (chicken-and-egg). All core DM
  targets must be `y` (built-in): `BLK_DEV_DM`, `DM_SNAPSHOT`, `DM_VERITY`,
  `DM_ZERO`, `DM_WRITECACHE`, `DM_INTEGRITY`.

---

## Boot Flow

```
RPi GPU firmware (start4.elf)
  └── reads config.txt, loads kernel8.img + bcm2711-rpi-4-b.dtb + ramdisk.img
        └── Linux kernel 6.6.78-v8+
              └── first-stage init (from ramdisk)
                    reads fstab.rpi4 → mounts /system /vendor /product
                    mounts selinuxfs → /sys/fs/selinux
                    └── second-stage init (/system/bin/init)
                          reads init.rpi4.rc
                          starts Android services
```

---

## Current Status

### Working
- [x] Kernel boots on RPi4 (6.6.78-v8+), built via merge_config
- [x] Serial console on ttyAMA0 (+ HDMI mirror via `console=tty1`)
- [x] HDMI framebuffer output (firmware fb / bcm2708_fb)
- [x] SD card partition layout and flash script
- [x] AOSP system/vendor/product images build
- [x] First-stage init mounts /system + /vendor
- [x] **`/data` mounts r/w** (mount_all in `on fs`) — keystore2 healthy
- [x] **APEX decompress + activate** completes (`apexd.status=activated`)
- [x] **netbpfload succeeds** (`rc:01`) — no more `netbpfload-missing` reboot
- [x] `adbd` starts
- [x] KeyMint HAL, VINTF, cgroups/PSI (see Changelog)

### Current blocker
- [ ] **SurfaceFlinger crash-loops (SIGABRT).** Boot reaches zygote, then
      `surfaceflinger` aborts and is restarted forever
      (`exited 4 times before boot completed` → apexd attempts a revert).
      Root cause: **no graphics stack** — only `gralloc.default.so` (a stub),
      no allocator service, no composer HAL, no EGL/GLES driver. Android's
      framework cannot reach `boot_completed` without a working SurfaceFlinger,
      so this is the gate for everything else (including AAOS).
      See **Graphics bring-up** below.

### Other known issues
- [ ] SELinux permissive (`androidboot.selinux=permissive`) — fine for bring-up;
      device policy under `sepolicy/` still TODO before enforcing.
- [ ] APEX decompression is slow on SD (~110 s, one-time per /data wipe).
      Consider `PRODUCT_COMPRESSED_APEX := false` to ship plain `.apex`.

### Still Needed

#### SELinux policy (`device/rpi/rpi4/sepolicy/`)
The directory is declared in `BoardConfig.mk` (`BOARD_SEPOLICY_DIRS`) but not
created yet. Minimum needed:
```
sepolicy/
├── file_contexts        ← label SD card block devices and device nodes
├── property_contexts    ← label rpi4-specific properties
└── device.te            ← allow rules for rpi4 hardware access
```

#### Graphics bring-up (THE current blocker — full HW-accel path chosen)

Target: HDMI display with GPU acceleration via **Mesa v3d**. All source is
already in the tree (`external/mesa3d`, `external/minigbm` with a `vc4` backend,
`external/drm_hwcomposer`). The whole stack must land together — SurfaceFlinger
needs gralloc + composer + EGL all present at once or it keeps crashing.

| # | Component | Plan |
|---|-----------|------|
| 1 | Kernel | `DRM_VC4=y` + `DRM_V3D=y` (they are `=m` in the base defconfig). Put them in the **android fragment** so the merge keeps them; bump CMA for framebuffers. |
| 2 | Firmware DT | Enable the `vc4-kms-v3d` overlay — but use the **kernel-matched** `.dtbo`, NOT the firmware's prebuilt one (see lesson below). |
| 3 | Gralloc | minigbm allocator + mapper with the vc4 backend: `android.hardware.graphics.allocator-service.minigbm`, `mapper.minigbm`, `gralloc.minigbm`; `ro.hardware.gralloc=minigbm`. minigbm `platform` soong var + ensure `DRV_VC4` is compiled in. |
| 4 | Composer | `android.hardware.composer.hwc3-service.drm` (drm_hwcomposer) — ships its own init.rc + VINTF fragment. |
| 5 | Mesa | build Mesa with `v3d vc4` Gallium drivers; `ro.hardware.egl=mesa`. |
| 6 | VINTF | composer3 + allocator declarations (mostly auto from their fragments). |
| 7 | SELinux | deferred (permissive) — clean up denials later. |

**Lesson learned the hard way (do NOT repeat):** enabling
`dtoverlay=vc4-kms-v3d` using the **firmware's** prebuilt `vc4-kms-v3d.dtbo`
against our **custom-built kernel DTB** scrambled the device tree — it bound the
SD controller to the wrong driver and killed the PL011 UART, giving a
first-stage reboot loop with no serial. Overlays must come from the **same
kernel source** as the base DTB. The boot package currently copies firmware
overlays from `vendor/rpi-firmware/boot/overlays`; for KMS we must instead ship
`kernel/rpi/rpi4/arch/arm/boot/dts/overlays/vc4-kms-v3d.dtbo`.

Until this stack is in, SurfaceFlinger has no composer and crash-loops.

#### Audio HAL
No audio HAL configured. The RPi4 has:
- HDMI audio (via bcm2835-audio ALSA driver)
- 3.5mm jack (PWM-based, `snd_bcm2835`)
Needs `android.hardware.audio@*` AIDL/HIDL HAL wired to ALSA via TinyALSA.

#### Wi-Fi / Bluetooth
The RPi4 has an on-board BCM43455 (brcmfmac driver for Wi-Fi, btbcm for BT).
Needs:
- Firmware files in `/vendor/etc/firmware/` (from `vendor/rpi-firmware/`)
- `android.hardware.wifi` HAL (wpa_supplicant)
- `android.hardware.bluetooth` HAL

#### USB / ADB
ADB over TCP is configured in `init.rpi4.rc` (`adb connect <ip>:5555`).
USB gadget ADB (`/dev/block/by-name` + `configfs`) needs:
- `dwc_otg` or `dwc3` gadget driver enabled in kernel
- `init.usb.rc` configfs setup

#### Power HAL
Stub power HAL declared in manifest. A real implementation should handle:
- CPU frequency scaling (cpufreq ondemand/schedutil)
- Thermal management (BCM2711 has thermal throttling in the DT)

#### Health HAL
Declared in manifest. For a device without a battery, a stub `IHealth` that
reports AC power is sufficient.

#### Camera
No camera HAL. If a Pi Camera module is used later, this requires:
- V4L2 / libcamera integration
- `android.hardware.camera.provider` HAL

---

## Troubleshooting

### Blank serial terminal after kernel rebuild
Most likely cause: `CONFIG_SERIAL_AMBA_PL011` is not compiled in. This happens
when you build with `make bcm2711_android_defconfig` alone — that file is a
fragment and does not include RPi4 hardware drivers. Always use the merge build
process (bcm2711_defconfig + merge_config.sh + bcm2711_android_defconfig).

Also ensure the SD card was actually reflashed after the rebuild — always run
`rpi4_boot_package.sh` then `flash_rpi4.sh` together after any kernel change.

To verify what's in a built kernel before flashing:
```python
python3 -c "
import zlib, struct, gzip, io
data = open('out/target/product/rpi4/boot_fat/kernel8.img','rb').read()
raw = gzip.GzipFile(fileobj=io.BytesIO(data)).read()
idx = raw.find(b'IKCFG_ST'); pos = idx + 18
cfg = zlib.decompress(raw[pos:pos+200000], -15)
for l in cfg.decode().split('\n'):
    if 'PL011' in l or 'LSM' in l: print(l)
"
```

### `init: mount selinuxfs failed: Invalid argument`
`CONFIG_LSM` was empty. SELinux is compiled in but must be listed:
```
CONFIG_LSM="capability,audit,selinux"
```
Rebuild kernel, re-package, re-flash.

### Board reboots with `reboot: Restarting system with command 'bootloader'`
Android init hit a fatal error. Check serial output. Common causes:
- Missing HAL service binary crashing at startup
- SELinux denial in enforcing mode blocking a critical operation
- `fstab.rpi4` partition not found (wrong `mmcblk0pN` number)

### Reboot loop with `reboot,netbpfload-missing`
Misleading reason — the real cause was `/data` not mounting. Without `/data`,
the `com.android.tethering` APEX cannot decompress to `/data/apex/decompressed`,
so the `bpfloader` service stays the `/system/bin/false` placeholder and exits 1.
Fix: ensure `/data` mounts (fstab mount point `/data`, and an `on fs / mount_all`
in `init.rpi4.rc`). Look for `EXT4-fs (mmcblk0p6): mounted ... r/w` in the log.

### First-stage reboot loop + dead serial right after enabling a dtoverlay
The firmware applied a **prebuilt overlay that doesn't match the custom kernel
DTB**, corrupting the device tree (SD bound to the wrong MMC controller, PL011
disabled). Symptoms: `partition(s) not found … reboot,bootloader`, nothing on
serial. Fix: use the overlay `.dtbo` built by the **same kernel** as the base
DTB, or don't apply that overlay. (This bit us with `vc4-kms-v3d`.)

### Partitions not found / `bcm2835-mmc 7e300000.mmc` is mmc0 (not the SD slot)
The SD-card controller (`sdhci-iproc`, `fe340000.mmc`) has no driver because the
kernel was built from the android fragment alone. Rebuild via merge_config so
`CONFIG_MMC_SDHCI_IPROC` / `CONFIG_MMC_BCM2835_*` are present.

### ADB not connecting
After Android boots: `adb connect <rpi4-ip>:5555`. The IP is assigned by DHCP
via the BCM GENET ethernet driver (already in the kernel). Check with:
```bash
# on the RPi over serial
getprop dhcp.eth0.result
ip addr show eth0
```

---

## Useful Commands

```bash
# Monitor serial boot log
picocom -b 115200 /dev/ttyUSB0

# ADB over network
adb connect <rpi4-ip>:5555
adb -s <rpi4-ip>:5555 shell

# Check Android boot state
adb shell getprop sys.boot_completed
adb shell getprop ro.product.device
adb shell getprop ro.build.version.release

# Check SELinux mode
adb shell getenforce

# Check kernel log
adb shell dmesg | grep -E "init|selinux|binder"

# Rebuild kernel only (from aosp root)
cd kernel/rpi/rpi4
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make bcm2711_defconfig
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- scripts/kconfig/merge_config.sh -m .config arch/arm64/configs/bcm2711_android_defconfig
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make olddefconfig
ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- make -j$(nproc) Image.gz dtbs
cd ~/android/aosp
cp kernel/rpi/rpi4/arch/arm64/boot/Image.gz device/rpi/rpi4/kernel/Image.gz
cp kernel/rpi/rpi4/arch/arm64/boot/dts/broadcom/bcm2711-rpi-4-b.dtb device/rpi/rpi4/kernel/
bash device/rpi/rpi4/rpi4_boot_package.sh
sudo bash flash_rpi4.sh /dev/sdX
```

## Silencing boot-log noise (serial debugging)

With `androidboot.selinux=permissive`, the kernel logs **every** SELinux denial
(`type=1400 … avc: denied …`) plus `audit: backlog limit exceeded` — a flood that
buries the lines that matter (crash backtraces, the actual boot blocker) and slows
the 115200-baud serial console. Permissive denials are informational only (nothing
is being blocked), so it is safe to mute them while bringing the board up.

### Quick — mute the serial console at runtime (no reflash)
On the serial **root** shell:
```bash
# only KERN_EMERG..ALERT reach the console; avc/audit/init spam goes quiet
echo 1 > /proc/sys/kernel/printk      # (same as: dmesg -n 1)
```
The messages are still captured in the ring buffer (`dmesg`) and by `logcat`/`logd`
— they just stop scrolling the serial console. Revert with `echo 7 > /proc/sys/kernel/printk`.

### Persistent — quiet from boot via `boot/cmdline.txt`
Edit `device/rpi/rpi4/boot/cmdline.txt`, then repackage boot + reflash **p1** only:
- `loglevel=1` (or `quiet`) — low kernel console verbosity from the first line.
- `audit=0` — disables the kernel audit subsystem, which **kills the entire
  `avc: denied` + `audit_backlog` flood** at the source. Safe while SELinux is
  permissive; **remove it before going enforcing** (you'll want denials back to
  author policy).
```bash
# after editing cmdline.txt:
bash device/rpi/rpi4/rpi4_boot_package.sh
sudo mount /dev/sdX1 /mnt && sudo cp -r out/target/product/rpi4/boot_fat/* /mnt/ && sudo umount /mnt
```

### Reading logcat without the spam
```bash
logcat -b crash -d              # ONLY Java/native fatal crashes — best for system_server aborts
logcat -d *:E                   # errors and above
logcat -d -s SurfaceFlinger     # a single tag
logcat -d | grep -ivaE "avc:|denied|audit"   # strip the permissive-SELinux noise
```
Note: the recurring `flags_health_check … avc: denied` lines in `logcat` are the
permissive-mode denial sweep; `audit=0` above removes them from the kernel log, and
the `grep -v` filter removes them from `logcat` output.
