# How we got here

An engineering notebook turned into a story: how this project went from "the Nano is stuck at Ubuntu 18.04 / CUDA 10.2" to "Ubuntu 26.04, mainline Linux 6.18, CUDA 12.6 and PyTorch 2.14 on a Maxwell GPU". It is written so you can retrace the reasoning and reuse the findings for other Tegra boards or other distributions. It is not a how-to; for that, see [install.md](install.md). For the result in detail see [architecture.md](architecture.md), [gpu-cuda.md](gpu-cuda.md), [pytorch.md](pytorch.md), [camera.md](camera.md) and [benchmarks.md](benchmarks.md).

Everything below comes from our working log. Where something was assumed rather than verified, it says so. All of it was done on one board (Jetson Nano Developer Kit B01, SD card, RAM code 0), so treat every number as "worked for us once", not as a guarantee.

## 1. Starting point and the key question

The original Jetson Nano 4 GB (Tegra X1 / T210, Maxwell GPU GM20B, compute capability 5.3) is stuck at JetPack 4.6: Ubuntu 18.04, kernel 4.9, CUDA 10.2. NVIDIA's newer JetPack releases target newer chips.

The question was not "can we boot a newer Ubuntu?" (mainline Linux boots on T210 fine) but:

> Does anything in the CUDA 12 stack still know how to talk to a GM20B, or has Maxwell been removed from it?

If the closed userspace (libcuda) had dropped Maxwell, the project would be dead on arrival. So the first step was to find out, cheaply, before writing any kernel code.

## 2. Step 1: reading the userspace

**Method.** Static analysis with `objdump` and `strings` on `libcuda.so` from three JetPack releases, looking for:

- the Maxwell GPU class IDs (compute `0xB1C0`, compute A `0xB0C0`, GPFIFO channel `0xB06F`),
- an Ampere class (`0xC7C0`) as a control,
- explicit compares against the Tegra X1 chip IDs,
- `sm_50/52/53` strings.

**Legal and practical note.** This was static analysis of binaries obtained legitimately from NVIDIA's own JetPack/L4T packages, done to understand interoperability with a GPU that NVIDIA no longer supports in its own kernel. No NVIDIA binaries are redistributed by this repository; the installer downloads them from NVIDIA's package repository on your machine.

**Findings** (number of hits for each class ID in the file):

| File | Origin | Size | `0xB1C0` | `0xB0C0` | `0xC7C0` | sm_50/52/53 strings |
|---|---|---|---|---|---|---|
| libcuda r32.6 | JetPack 4.6 (CUDA 10.2), what the Nano ships with | 16 MB | 10 | 6 | 0 | no |
| libcuda r35.6 | JetPack 5.1.4 (CUDA 11.4) | 23 MB | 12 | 10 | 3 | yes |
| libcuda r36.4 | JetPack 6.2 (CUDA 12.6) | 42 MB | 7 | 5 | 1 | yes |

Even in the JetPack 6 library there are code paths that branch specifically on Maxwell classes: a compare on `0xB1C0` with its own branch, a device-context class table that registers `0xB1C0` and `0xB06F`, and a debugger mapping from class to architecture for `0xB0C0`/`0xB1C0`. Our reading was that Maxwell code was probably not removed because libcuda shares code with the desktop driver. At that point that was a hint, not proof.

The decisive follow-up was the chip ID. It is composed as architecture | implementation, so GM20B is `0x120 | 0xB = 0x12B` and GM20B_B (T210B01) is `0x12E`. libcuda r36.4 compares explicitly against `0x12B` and `0x12E` in about 14 places, often as a pair (`cmp x5,#0x12b; b.eq ...; cmp x5,#0x12e; b.eq ...`). A desktop driver does not know `0x12E`, so this is Tegra X1 specific code that NVIDIA left in.

Two more results from the same pass:

| Finding | Consequence |
|---|---|
| `libnvrm_gpu.so` r36.4 (the shim between libcuda and the kernel, from `nvidia-l4t-core`) contains the chip names GM20B, GP10B, GV11B, GA10B | The userspace layer still knows GM20B |
| r36 opens `/dev/nvgpu/igpu0/...`; the Nano's old nvgpu 4.9 only provides `/dev/nvhost-*-gpu` | The old kernel driver cannot work. The new nvgpu (nvidia-oot from R36) is required |
| libcuda r36 needs glibc 2.17, libnvrm_gpu r36 needs glibc 2.34 | Ubuntu 22.04 or newer; Ubuntu 20.04 (glibc 2.31) is not enough |

Interim conclusion at that point: the application side of JetPack 6 still knows the Nano GPU; the main work would be in the kernel driver.

## 3. Step 2: the kernel side

Next question: is the kernel driver for GM20B still around in R36? The open sources (GitHub mirror OE4T/linux-nvgpu, branch `l4t/l4t-r36.5`, compared with `l4t/l4t-r32.7.6`, the Nano's original) say yes:

- GM20B is fully present: 169 files in R36.5 versus 73 in R32.7.6 (the difference is mostly test code added since).
- `hal/init/hal_init.c` still has `case GK20A_GPUID_GM20B` and `GM20B_B` under `CONFIG_NVGPU_HAL_NON_FUSA`, which is on by default.
- `hal_gm20b.o`, `clk_gm20b.o`, `gr_gm20b.o` and `platform_gk20a_tegra.o` are built.
- The device-tree match `"nvidia,tegra210-gm20b"` is still in `os/linux/module.c`.
- The ACR firmware-loading logic for GM20B and GM20B_B is present.
- The T210 platform file wraps its dependencies on the old L4T kernel (DVFS, EMC bandwidth manager, soctherm, nvmap-next, Tegra MC) in `#ifdef`s, so it can in principle be built without them.
- OE4T/nvidia-kernel-oot already has a branch `wip-r36.5-6.18` that builds the R36.5 modules against kernel 6.18.

That turned "impossible" into "a list of porting gaps". Our first guess at the gaps (written down before we tried anything):

1. a device-tree node for the GPU with compatible `nvidia,tegra210-gm20b`, clocks, resets and power domain (mainline describes the GPU as `nvidia,gm20b`, for nouveau),
2. host1x / syncpoints and nvmap running on T210,
3. GM20B firmware (FECS/GPCCS/PMU) taken over from L4T 32,
4. no DVFS/EMC scaling at first (fixed clock is acceptable),
5. camera as a separate risk.

Reality was close to that list, but the details were different. How each gap was closed is documented in [gpu-cuda.md](gpu-cuda.md); here is the path we actually took.

**Build setup.** A persistent arm64 Linux container on the Mac builds the kernel (the Mac filesystem is case-insensitive, so do not build on the host mount). The out-of-tree modules are built in this order: mc-utils, host1x, host1x-fence, host1x-nvhost, nvmap, nvgpu. The kernel itself had to be built without its own host1x and DRM_TEGRA at first, because the names clash with the out-of-tree host1x. The Mac had only about 9 GB free, which became a recurring limit (see section 7).

**Bring-up order that worked:**

1. Mainline 6.18 boots with the existing Ubuntu 20.04 rootfs through its own extlinux menu entry. The original L4T entry stays the default.
2. All six out-of-tree modules compile against 6.18 with one patch (host1x provides the context bus itself, nvmap without SciIpc, a prototype fix). `nvgpu.ko` contains the alias `nvidia,tegra210-gm20b`.
3. `nvgpu` loads and binds to `57000000.gpu` once the compatible string in the DTB is changed (done with `fdtput`). `/dev/nvgpu/igpu0/*` appears.
4. A set of T210-specific paths (marked `T210_MAINLINE` in the patch): supply via `vdd-supply` (fixed 1.0 V at first), clocks `gpu/ref/pwr` from the DT, reset `gpu`, `tegra_powergate_remove_clamping(3D)`, no rail-gating, optional host1x, reference clock 38.4 MHz, fuses via `tegra_fuse_readl` when there is no nvmem cell. `gpcclk` has to be registered with `dev=NULL` or it deadlocks in runtime PM.
5. Firmware: one symlink, `nv_acr_ucode_prod.bin -> acr_ucode.bin` in `/lib/firmware/gm20b/`. After that the ACR bootstrap ran without error.

**The first big bug: the SMMU.** `gm20b_gr_falcon_ctx_wait_ucode` timed out (mailbox 0) and FECS had empty IMEM and PC=0. The cause was not firmware: under mainline the GPU node had an `iommus` property pointing at the Tegra SMMU. nvgpu mixed IOVA and physical addresses (SMMU bit 34), which produced SMMU faults and an MMU fault from GPCCS; the fault handler then blocked, the LS-PMU never got its interrupts and never booted FECS. Fix: remove `iommus` from the GPU node in the DTB (the GPU then runs with its own GMMU, as under L4T), and make the fault handler log and acknowledge faults that arrive before GR init. After that `arch=0x120 impl=0xb rev=0xa1` was read back and dmesg was clean.

Lesson: when a falcon does not start, look at memory translation and fault handling before you suspect the firmware.

## 4. Step 3: getting CUDA 12.6 to run

With the GPU powered, the first CUDA test was a tiny Driver-API program: `cuInit`, device count 1, name `NVIDIA Tegra X1`, compute capability 5.3, allocate, copy, JIT a PTX kernel for sm_53, launch, synchronise, 1M-element vector add. All `CUDA_SUCCESS`. The userspace was R36.4 libcuda (12.6) in an Ubuntu 22.04 chroot (glibc 2.35) under the old system.

What had to be solved on the way:

| Problem | What we did |
|---|---|
| No `/dev/nvmap` | nvmap creates its platform device itself when there is no `tegra-carveouts` DT node (patch in `nvmap_init.c`) |
| libcuda aborted with `CUDA_ERROR_NOT_SUPPORTED` | libnvrm_host1x wanted `/dev/dri` (tegra-drm) or `/dev/nvhost-ctrl`. First workaround: a small `LD_PRELOAD` shim returning a dummy handle from `NvRmHost1xOpen`. Environment switches such as `NVRM_GPU_NVGPU_NO_SYNCPOINTS` did not help |
| `tegra_fuse` parameters | Faked (chip_id 33) through an overlay on `/sys/module`. Whether this is strictly necessary was never checked |
| Device nodes and permissions | udev rules `60-tegra-gpu.rules` (group video/render, 0660) |
| `nvgpu` cannot be reloaded | `rmmod` returns EBUSY or hangs. One boot per experiment |

**The shim was replaced by real syncpoints.** What libnvrm_host1x (JetPack 6) wants: a `/dev/dri/renderD*` node whose driver name is `tegra`, the host1x UAPI of tegra-drm (for example `SYNCPOINT_WAIT` `0x22`), and `/dev/host1x-fence`. The kernel was rebuilt with in-tree `TEGRA_HOST1X=m` and `DRM_TEGRA=m` plus `DRM_TEGRA_STAGING=y`. The staging option matters: without it the new tegra-drm ioctls are missing from the table, you get EINVAL, and `cuMemcpy` fails. The out-of-tree host1x and host1x-nvhost are no longer built; nvgpu only needs the host1x API that the mainline host1x exports. The `host1x-fence` module was extended to match T210 and to export `host1x_fence_extract()`, which does not exist upstream (it is a copy of a kernel struct and must match the kernel in use). Proof that the real path is used: `SYNCPOINT_WAIT id 8 threshold 726` in the ioctl log. After this, `deviceQuery` and `bandwidthTest` from cuda-samples v12.5 passed without any shim.

A note on the chroot: bind mounts must be made with `--make-rslave`, otherwise `umount -R` detaches the host's `/dev` and `/sys` and the machine becomes unreachable (it cost us a power cycle).

**GPU clock and voltage.** The first runs were at the boot clock of 217.6 MHz. For scaling we took the voltage/frequency pairs from the L4T 4.9 DVFS debugfs table (460 MHz 818 mV, 537 MHz 848, 614 MHz 888, 691 MHz 928) and put a static table into the platform file: raise voltage before raising the PLL, lower it afterwards. A simple FMA loop confirmed the clock actually changed (217.6 MHz 472.8 ms, 614 MHz 167.1 ms, 640 MHz 160.5 ms, a factor of 2.95). 640 MHz at 928 mV became the maximum.

**The freeze that was not a brownout: nvmap and the cache.** The first PyTorch test froze once. The last kernel line before the stall was `PBDMA intr GPPTR invalid`, 0.9 s after the GPU reached 640 MHz, and power was only 4 to 5 W, so it did not look like a supply problem. It never reproduced in single-step tests. By reading the code we found the likely cause: nvmap built with `NVMAP_UPSTREAM_KERNEL` uses `arch_invalidate_pmem()` for write-back plus invalidate, which on arm64 only invalidates (`dc ivac`) and discards dirty CPU cache lines. T210 is not IO-coherent, so the GPU could read stale GPFIFO or pushbuffer data. The fix replaces that in four places with a module-local clean-and-invalidate (`dc civac`). nvmap statistics show about 14 MB of cache flushes per test run, so the path is used. The cause of the `GPPTR` error was not proven (it occurred only once), but 13 consecutive runs and later long loops did not freeze again. If you port nvmap to another non-coherent Tegra, check this first.

A deliberate MMU fault test (CUDA error 719) was handled cleanly and the GPU stayed usable afterwards.

## 5. Step 4: memory clock (EMC) and trained tables

Symptom: `bandwidthTest` gave 1.2 / 1.2 / 2.3 GB/s (H2D / D2H / D2D). The EMC was stuck at 204 MHz (`no memory timings for RAM code 0`), whereas L4T runs it at 1600 MHz.

Why: `CONFIG_TEGRA210_EMC` was off, and the mainline driver expects a table trained by the bootloader (a binary `struct tegra210_emc_timing` in reserved memory), with no training in the driver. NVIDIA's bootloader trains on every boot but writes the result only into its own L4T device tree (`DT Write: emc-table@...`, `nvidia,trained = 1`). Earlier upstream U-Boot patches that pass the table via reserved memory did not fit the U-Boot on this board.

What we did:

1. Read the live FDT of a running L4T system (`/sys/firmware/fdt`).
2. A script converts the table for RAM code 0 into a binary blob (204 and 1600 MHz entries, 4928 bytes each, plus a zero terminator).
3. A kernel patch makes tegra210-emc read the table from the DT property `nvidia,emc-table`; the deploy script writes it into the DTB with `fdtput -t bx`.

Result: 8.9 / 9.0 / 15.4 GB/s, the same test. Caveats from the log: the training values come from one L4T boot (two boots differed by 1 to 3 taps); with other RAM or another board the table has to be taken from L4T again. There is no actmon/devfreq, so the clock is set by a small service writing `/sys/kernel/debug/emc/min_rate`.

## 6. Step 5: a modern userspace without giving up the old system

The 22.04 chroot proved the idea, but the goal was a normal Ubuntu 26.04. The design that worked:

- Build the rootfs (`ubuntu-base` 26.04.1 plus apt, 2.7 GB) in a subdirectory, `/opt/u2604`, on the existing L4T partition.
- Use a tiny initramfs (busybox-static, about 1 MB) that bind-mounts `/opt/u2604` as `/` and the real partition under `/media/l4t`.
- Add one more entry to `extlinux.conf` and leave the default entry pointing at the original L4T system.

Why this design:

| Reason | Detail |
|---|---|
| L4T stays bootable | The default entry is untouched; a failed experiment costs a power cycle, not a re-flash. During development a hang was recovered simply by cycling power, after which the board booted L4T automatically |
| No repartitioning | The SD card layout and the QSPI bootloader (U-Boot, reading `/boot/extlinux/extlinux.conf`) are not touched |
| Kernel and modules live outside the rootfs | They stay in `/boot/mainline`, so `apt upgrade` inside Ubuntu cannot replace them. We additionally pin kernel, bootloader and NVIDIA packages with apt preferences, and put 27 `nvidia-l4t-*` packages on hold in the L4T system |
| The JetPack 6 libraries drop in | L4T r36.4 libraries live in `/usr/lib/aarch64-linux-gnu/nvidia`; cuda-cudart and cuBLAS 12.6 come from the Jetson repository, which is removed afterwards so apt never pulls L4T kernel packages |

Details we learned:

- Do not blacklist `nvgpu`; systemd-modules-load then refuses to load it. Use `modules-load.d`.
- The fake-fuse overlay on `/sys/module` makes that tree read-only, which has side effects: `lsmod` prints errors (use `cat /proc/modules`), and runtime module parameters can only be changed through a second sysfs mount. Earlier `echo 640 >` attempts silently did nothing for this reason. A proper kernel-side replacement for the fuse parameters would remove the overlay.
- CUDA 12.6 headers do not compile with glibc 2.43 as they are: `rsqrt`, `sinpi` and `cospi` in `crt/math_functions.h` need `noexcept(true)`. A `sed` in the build script fixes it.
- USB never worked on mainline at first: the built-in tegra-xusb did not find `nvidia/tegra210/xusb.bin`. The firmware has to be inside the initramfs because the driver is built in.

## 7. Step 6: PyTorch, cuDNN, camera, robots

Brief; the details are in the linked documents.

**PyTorch** ([pytorch.md](pytorch.md)). Built from the v2.14.1 tag (the last with CUDA 12.6) for sm_53, Python 3.14, in an arm64 container on the Mac, then run on the Nano. The build was the most resource-hungry step:

- The Mac ran out of disk space twice (down to 3.2 GB free). The container disk grows but does not shrink, and builds were paused until space was freed.
- A recursive submodule clone is huge. Only the needed submodules are cloned, not recursively.
- `setup.py bdist_wheel` no longer exists in 2.14; the build uses `python -m build --wheel --no-isolation`.
- Some generated ATen files (`Register*`, `Operators_*`) need about 3.6 GB of RAM each in `cc1plus`. With 6 GB of RAM in the container the build was OOM-killed and the VM hung twice. Fix: a container with 10 CPUs and 12 GB, an ninja pool that builds the large files one at a time, and `USE_CPU_VECTORIZATION=0` (an existing switch, no patch) to avoid the SVE variants.
- Result: matmul 1024x1024 FP32 about 134 GFLOPS at 640 MHz (peak 164). torchvision 0.29.2 was built the same way in about a minute.

**cuDNN.** cuDNN 9.3.0.75 from the Jetson r36.4 repository does contain sm_53 SASS (checked with `cuobjdump`), so a build with cuDNN is possible, and we did it. It is slower (see next section), so the shipped wheel is built without it.

**Camera** ([camera.md](camera.md)). A research pass first established that the mainline `tegra-video` VI/CSI driver is still in staging, that IMX219 on the Nano is not a documented path, and that the libcamera Tegra handler was an unmerged RFC with no known hardware test. The recommendation was therefore: raw Bayer through V4L2, debayer with OpenCV, gray-world white balance and a simple exposure loop in software. On hardware the sensor needed only a device-tree description (sensor on I2C bus 2 address 0x10, reset GPIO, the board's I2C mux fixed to the camera port, two CSI lanes, `nvidia,mipi-calibrate`, 24 MHz fixed clock), with values copied from the L4T DTB, and no driver patch. Colour comes from a small Python module that debayers 1640x1232 RGGB8, applies shading and colour matrix from the vendor ISP file, and does white balance and gamma: 30 fps at 224x224 and 640x480.

**Robots** ([robots.md](robots.md)). JetBot and JetRacer parts are driven directly over I2C (smbus2), because the usual Adafruit libraries do not work on mainline. The notebooks were ported with replacement packages for camera and gamepad. One practical detail: the I2C bus at the 40-pin header was disabled in the mainline DTB and had to be enabled with `fdtput`.

## 8. Step 7: TensorRT after all

For a while the answer was "no TensorRT": TensorRT 10 (JetPack 6) has no sm_53 kernels, and TensorRT 8.2 needs CUDA 10.2. The JetBot object detection was replaced by a PyTorch model. Later we asked a different question: does the old stack really need the old driver? The CUDA driver is backward compatible with applications built for older toolkits. If the r36 `libcuda` runs a CUDA 10.2 application, then TensorRT 8.0 from the user's own JetPack 4.6 install might run on top of it. A small CUDA 10.2 runtime and cuBLAS 10 test worked, and then TensorRT worked. cuBLAS 10, cuDNN 8 and TensorRT 8.0 all contain sm_53 kernels, so nothing needs a JIT.

Only two libraries failed: `libnvmedia` and `libnvdla_compiler`. They talk to the old kernel ABI, and they belong to the DLA accelerator, which the Nano does not have. Two stubs that return 0 (and report 0 DLA engines) were enough. A small C interface (`trt_shim`, about 40 lines) lets Python call TensorRT through `ctypes`, in the same CUDA context as PyTorch. Nothing from NVIDIA is copied: the libraries are used from `/media/l4t` ([tensorrt.md](tensorrt.md)).

Three findings cost most of the time:

- **The watchdog.** The first engine builds froze the Nano. TensorRT times kernel candidates, and some run longer than the 7 s nvgpu watchdog. The watchdog recovery (channel teardown) in this nvgpu port leaves the GPU in a bad state (PRI timeouts, PMU DMEM errors) and hangs the whole board. Switching the watchdog off during the build fixed it. The wrapper `nano-trt build` does that and needs root for it.
- **Identity nodes.** The TensorRT 8.0 ONNX parser failed in `importConv`. The current PyTorch exporter puts Identity nodes in front of shared Conv weights. `nanotrt.export` removes them and writes opset 11 and IR version 6.
- **The postprocessing.** At 918 MHz the CPU was the bottleneck of the detector: torchvision's postprocessing loops over 90 classes. Taking the top 200 over all anchors and classes and running one `batched_nms` raised the PyTorch path from 5.4 to 12.1 fps, and TensorRT then reached 16.7 fps. Fix the pipeline before the model, again.

## 9. Step 8: comparison with the original L4T

With TensorRT running, the obvious question was how this system compares with NVIDIA's own. We measured both on the same board with the same clocks as far as possible (CPU at most 918 MHz, EMC 1600 MHz, GPU 640 MHz here and 614.4 MHz on L4T, which has no 640 MHz step). To avoid trusting the clock settings, the real SM clock was measured with a `%clock64` kernel against wall time: 640.1 and 614.5 MHz. Where possible both systems ran the same binaries (`bandwidthTest`, `matrixMulCUBLAS`, identical TensorRT engines).

Result: with TensorRT the new system is as fast as L4T per clock. Plain PyTorch is faster in FP16 here, L4T is faster in FP32 thanks to cuDNN 8. Only cuBLAS GEMM is 10 to 13 % slower per clock here, and we did not find the cause. The L2/LTC debugfs switch shows N, but toggling it changes nothing. Later checks ruled out more causes (clock, page size, memory controller, power gating); see [benchmarks.md](benchmarks.md#open-cublas-gemm-per-clock). Lesson: to separate driver or configuration effects from library choices, compare the same binary and the same engines on both systems. That is how we saw that TensorRT is equal per clock and only cuBLAS differs. The table is in [benchmarks.md](benchmarks.md#comparison-with-nvidia-l4t).

The kernel was also moved from 6.18.0 to 6.18.62 (longterm) in this phase. The tested kernel configuration is now stored as `kernel/config-6.18-t210`, because the defconfig path of the build script misses options that `nvmap` needs (for example `ARM64_PMEM`). All benchmarks were unchanged after the update.

## 10. Dead ends and surprises

| Item | What happened | Takeaway |
|---|---|---|
| cuDNN is slower | resnet18 FP16: 15.0 fps with cuDNN versus 18.2 without; FP32 13.7 versus 15.4; also with `cudnn.benchmark` | Do not assume the vendor library wins on a 1-SM Maxwell part. Measure |
| Power supply looks like a software bug | Hangs with no log: 4 cores at 1428 MHz or more under load (SError, PMU exterr), a fresh cable on a 4 A supply, and even a hang under the cuDNN benchmark with a clean log. A different supply (the Waveshare battery board with 3x18650) ran 918, 1428 and the maximum (1555 MHz; the kernel caps the requested 1912 MHz) with CPU plus GPU load for 5 minutes each without a crash, at about 45 C | If the log stops silently, suspect the supply before the kernel. With micro-USB the CPU is capped at 918 MHz |
| One real freeze, not explained | `PBDMA intr GPPTR invalid` once; cache-flush bug is the probable cause, not proven | Keep the serial console with `dmesg -n 8` running when you stress a new GPU port |
| USB firmware | Built-in xusb driver loads firmware before the root filesystem exists | Put firmware into the initramfs |
| Read-only `/sys/module` | A side effect of the fake-fuse overlay | Prefer a kernel-side solution if you can |
| `nvgpu` cannot be reloaded | `rmmod` hangs or returns EBUSY | Plan one boot per test; script the reboot and the power cycle |
| TensorRT is not possible | TensorRT 10 (JetPack 6) has no sm_53 kernels; TensorRT 8.2 needs CUDA 10.2 | Wrong in the end: the r36 driver runs CUDA 10.2 applications, so TensorRT 8.0 from the user's L4T works (section 8). Do not stop at the first 'not supported' |
| Watchdog recovery hangs the Nano | TensorRT engine builds ran kernels longer than the 7 s watchdog; the recovery left the GPU in a bad state | Switch the watchdog off for the build (`nano-trt build`) |
| Max CPU clock on a micro-USB supply | A short test at max made the GPU firmware fail (registers read 0xbad00100) without a full hang | Test max clocks under CPU and GPU load before keeping them (`nano-power test`) |
| Faster resnet variants rejected | 160x160 gave 34 fps and 128x128 gave 49 fps, but mean deviation of the road-following output was 0.76, so they were dropped | Speed is only useful when the output stays the same |
| Real speed-up came from the camera thread | End-to-end road following went from 11.9 to 17.3 fps by capturing in its own thread; `channels_last`, `jit.trace`, CUDA graphs gave nothing (the GPU is the bottleneck) | Fix the pipeline before the model |
| `scp` hangs | Persisted even with `openssh-sftp-server` installed; not investigated further | Small files via base64, large ones via a temporary HTTP server |
| Stale clock readout | `gpcclk/clk_rate` in debugfs shows 217.6 MHz; the real clock appears in dmesg (`vdd-gpu 928 mV for 640000 kHz`) | Measure performance, do not trust one sysfs file |
| Xbox mode of the gamepad | Needs `xpad`, not built | Use the PC mode |
| Camera limits | Slightly bluish in mixed light, shading correction only for 4000 K, no highlight protection in auto exposure; an occasional `frame start syncpt timeout` at stream start, stable afterwards | |
| Power savings | Not measurable (no power monitor reachable), so `tegra-dvfs` only claims "no performance loss" | |
| DVFS | Switching GPU and EMC under load was tested with 427 and 435 random switches over 2 minutes each, with result checking: 0 errors, no kernel messages | A two-level scheme is easy to verify; a full governor would need more tests |

## 11. Reusable lessons and checklist

For another Tegra board (for example other T210/Maxwell parts, or a different generation), or for a different distribution:

1. **Check the userspace first.** Count class-ID hits and chip-ID compares in the vendor `libcuda` and its RM shim (`objdump`, `strings`); it takes an afternoon and decides whether to continue. Compare the board's original release with the newest one.
2. **Check what the userspace expects from the kernel.** Device node names and paths (`/dev/nvgpu/igpu0`, `/dev/dri/renderD*`, `/dev/host1x-fence`), the host1x UAPI, glibc minimum. A strace of a failing `cuInit` tells you faster than reading code.
3. **Check whether the open kernel driver still has the chip.** Grep the vendor's current branch for the chip ID and the DT compatible, and look for an existing out-of-tree port to a recent mainline kernel.
4. **Keep the vendor system bootable.** Separate boot entry, default unchanged, serial console, and a way to cycle power remotely.
5. **Bring up in small, observable steps:** boot, modules build, driver binds, power-on, falcon start, tiny Driver-API test, then samples, then frameworks.
6. **When a falcon or engine does not start, suspect address translation and fault handlers** (SMMU, IOMMU properties in the DT) before firmware.
7. **On non-IO-coherent SoCs, audit every cache maintenance call** in the memory manager port. An "invalidate only" substitute is a silent corruption risk.
8. **Take tuning data from the running vendor system:** DVFS tables from debugfs, the live device tree for memory timings and camera nodes. Our EMC and camera DT values were all copied this way.
9. **Treat the power supply as a suspect from the beginning,** and record voltage, current and clock settings with every hang report.
10. **Measure instead of assuming.** The vendor library (cuDNN) and the clever tricks (`channels_last`, CUDA graphs, lower resolution) were all either slower or changed the output.
11. **Plan build resources.** Heavy C++ files can need several GB each; budget RAM per job, disk for the container, and keep scripts resumable.
12. **Automate the reboot-test loop** (boot menu selection over serial, power cycle, test script, log capture). Most of the calendar time went into reboots, not coding. Our log counts 6 power cycles for the EMC work alone.
13. **Protect the result from updates.** apt pins, held packages, pip constraints, and kernel/modules stored outside the rootfs.

For a different distribution: the Ubuntu 26.04 part has nothing Ubuntu-specific except the glibc lower bound (2.34 for the r36 shim) and the CUDA header/glibc incompatibility noted above. The initramfs bind-mount trick should work with any rootfs that can be unpacked into a subdirectory.

## 12. Timeline

All dates are from the working log. The work took place in one stretch.

| Date | Milestone |
|---|---|
| 2026-11-07 | Static analysis of libcuda (three JetPack versions), chip-ID and device-path findings, nvgpu R36.5 source survey |
| 2026-11-07 | Build container set up; mainline 6.18 boots with the old 20.04 rootfs; Wi-Fi works |
| 2026-11-07 | Out-of-tree modules compile against 6.18; nvgpu binds to the GPU; ACR bootstrap runs; FECS timeout |
| 2026-11-08 | SMMU `iommus` removed, FECS starts, GPU power-on succeeds |
| 2026-11-08 | First CUDA 12.6 test passes (Driver API, in a 22.04 chroot with a host1x shim) |
| 2026-11-08 | GPU clock and voltage scaling up to 640 MHz |
| 2026-11-08 | Real host1x/syncpoints replace the shim; `deviceQuery` and `bandwidthTest` pass |
| 2026-11-08 | Ubuntu 26.04 boots natively from `/opt/u2604`; CUDA 12.6 passes without chroot |
| 2026-11-08 | EMC at 1600 MHz from a converted trained table; bandwidth up about 7x |
| 2026-11-08 | IMX219 camera with software colour processing |
| 2026-11-08 | PyTorch 2.14.1 for sm_53 builds (after two OOM/disk-space aborts) and runs on the Nano; nvmap cache-flush fix |
| 2026-11-08 | JetRacer parts, torchvision, JupyterLab; cuDNN tested and rejected; power-supply tests |
| 2026-11-08 | JetBot conversion (USB firmware, gamepad, OLED, notebooks), update protection, simple DVFS service, SSDlite object-detection replacement for TensorRT |
| 2026-11-09 | Kernel 6.18.62, `nano-power`, TensorRT 8.0 from the L4T libraries, faster detector postprocessing, comparison with L4T, package updates (numpy 2.5, OpenCV 5.0), notebooks changed to resnet18 |

If you reuse any of this for a different board and learn something that contradicts the above, please open an issue; the single-board caveat applies to everything here.
