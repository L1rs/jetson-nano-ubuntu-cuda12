# GPU and CUDA

The GM20B GPU of the Tegra X1 is driven by `nvgpu` from OE4T's R36.5 sources (`wip-r36.5-6.18`), which targets the NVIDIA downstream kernel. Running it on a mainline 6.18 kernel needed changes in the kernel configuration, the device tree and the out-of-tree modules. The patches mark their T210-on-mainline code paths with `T210_MAINLINE`. Patches: `kernel/patches/oot-6.18-t210.patch` (nvidia-oot and nvgpu) and `kernel/patches/emc-t210-dt-table.patch` (Linux).

## What the patches do

**Power and clocks (nvgpu)**
- Supply via `vdd-supply` (the mainline regulator `vdd-gpu`); GPU clocks `gpu`, `ref`, `pwr` and the reset `gpu` come from the device tree; power domain clamping of the 3D domain is removed with `tegra_powergate_remove_clamping`; no railgating.
- Fuses are read with `tegra_fuse_readl` when no nvmem cell exists. `mc-utils` loads without the T234 memory controller.
- `gpcclk` is registered without a device (otherwise a runtime-PM deadlock), parent `pll_g_ref`, reference clock 38.4 MHz.
- **Static voltage/frequency table** (taken from the L4T 4.9 DVFS data), applied by `t210_gpu_vdd_set()` before a faster clock and after a slower one: 460 MHz 818 mV, 537 MHz 848 mV, 614 MHz 888 mV, 691 MHz 928 mV; the maximum used is **640 MHz at 928 mV**.
- The start rate is 640 MHz. It can be changed at runtime (range 77-640) via the module parameter `t210_gpu_mhz`; because `/sys/module` is a read-only overlay, write it through a second sysfs mount: `sudo mount -t sysfs sysfs /run/sysfs-rw; echo 614 | sudo tee /run/sysfs-rw/module/nvgpu/parameters/t210_gpu_mhz`. Normally `tegra-dvfs.service` does this (stop it first). There is no devfreq.
- Measured with a fused-multiply-add loop: 217.6 MHz 472.8 ms, 614 MHz 167.1 ms, 640 MHz 160.5 ms.

**GPU without SMMU.** On mainline the GPU node sits behind the Tegra SMMU, and nvgpu mixed IOVA and physical addresses, causing SMMU faults and a hang in the FECS bootstrap. The installer removes `iommus` from the GPU node; the GPU then uses its own GMMU as under L4T. The MMU fault handler was also changed to only log and acknowledge faults before GR init, and a missing `get_arbiter_clk_range` is handled.

**host1x syncpoints and fences.** The in-tree `TEGRA_HOST1X` and `DRM_TEGRA` (with `DRM_TEGRA_STAGING`) are used instead of the out-of-tree host1x. JetPack 6's `libnvrm_host1x` looks for a `tegra` DRM render node and uses the host1x UAPI (for example `SYNCPOINT_WAIT`) and `/dev/host1x-fence`. nvgpu's `nvhost_host1x.c` was adapted to `<linux/host1x.h>` and the `nvidia,tegra210-host1x` compatible (probe deferral until host1x is ready); `host1x-fence` matches T210 and exports `host1x_fence_extract()`, which is missing upstream (a copy of `struct host1x_syncpt_fence` that has to match the kernel).

**nvmap.** Without a `tegra-carveouts` node, nvmap creates its platform device itself. With `NVMAP_UPSTREAM_KERNEL` the cache write-back-and-invalidate used `arch_invalidate_pmem()`, which on arm64 only invalidates (`dc ivac`) and discards dirty CPU lines. T210 is not IO-coherent, so the GPU could read stale GPFIFO/pushbuffer data. The patch uses a module-local `__dma_flush_area` (`dc civac`) at four places. This is believed to be the cause of a one-time freeze seen before the fix; it was not reproduced afterwards.

**EMC 1600 MHz.** Mainline's `tegra210-emc` needs a memory timing table trained by the bootloader. The L4T bootloader trains at every boot but only writes the result into its own device tree. `kernel/emc-table.py` converts the table of the board's RAM code (204 and 1600 MHz) from the live L4T device tree into the binary `struct tegra210_emc_timing`; the kernel patch reads it from the property `nvidia,emc-table`; the installer inserts it with `fdtput`. The training values come from an L4T boot (two boots differ by 1-3 taps); the driver's periodic compensation runs. For other RAM or boards, the table is regenerated from L4T, which `install.sh` does for you. Effect on `bandwidthTest`: H2D/D2H/D2D 1.2/1.2/2.3 GB/s at 204 MHz became 8.9/9.0/15.4 GB/s at 1600 MHz.

## Userspace

CUDA 12.6 userspace comes from NVIDIA's L4T r36.4 packages (`libcuda` driver version 12060) plus the CUDA 12.6 runtime libraries from the Jetson apt repository. cuBLAS 12.6 contains sm_53 machine code, so no PTX JIT is needed for it. `nvcc` is not part of the installed system; the CUDA samples and the PyTorch wheels were built in a build container (see [pytorch.md](pytorch.md)).

A harmless message `Can't initialize nvrm channel` may appear on stderr.

## Stale clock readout

`/sys/kernel/debug/clk/gpcclk/clk_rate` shows **217.6 MHz**; this value is stale. The real clock is reported in `dmesg`, for example `vdd-gpu 928 mV for 640000 kHz`.

## Known restrictions

- `nvgpu` cannot be unloaded and reloaded (`rmmod` fails with EBUSY or hangs); reboot instead.
- No railgating. Clock scaling is done by `tegra-dvfs.service`, not by devfreq. TensorRT 8.0 works through the L4T libraries, see [tensorrt.md](tensorrt.md).
- A deliberate MMU fault is handled cleanly (CUDA error 719) and the GPU stays usable.
