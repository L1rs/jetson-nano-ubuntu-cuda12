# Architecture

## Boot chain

```
QSPI bootloader (NVIDIA, unchanged)
  -> reads /boot/extlinux/extlinux.conf on SD partition 1 (the L4T root file system)
     entry "u2604":  LINUX /boot/mainline/Image
                     INITRD /boot/mainline/initrd-u2604.img
                     FDT /boot/mainline/tegra210-p3450-0000.dtb
                     APPEND console=ttyS0,115200n8 earlycon root=PARTUUID=<p1> rw rootwait rootfstype=ext4 net.ifnames=0
  -> mainline Linux 6.18 starts the busybox initramfs (rootfs/init)
  -> initramfs mounts partition 1 and bind-mounts /opt/u2604 as the new root
     partition 1 itself is bound to /media/l4t in the new root
  -> switch_root to /sbin/init (systemd) of Ubuntu 26.04
```

There is no second partition: Ubuntu 26.04 lives in a directory (`/opt/u2604`) of the L4T partition. The old system is therefore available at `/media/l4t` and stays bootable through its own entry (`primary`). The initramfs is tiny (statically linked busybox plus `xusb.bin`); on the SD card the device is `mmcblk1` under mainline, hence `root=PARTUUID=`. The kernel command line argument `u2604root=` can change the directory.

The initramfs also contains the Tegra XUSB firmware because `tegra-xusb` is built in and loads firmware before the root switch.

## Kernel

Mainline Linux 6.18.62 (longterm; `V=${V:-6.18.62}` in `kernel/build-kernel.sh`; the release asset is `linux-6.18.62-t210-jetson-nano.tar.gz`). The build uses the tested configuration `kernel/config-6.18-t210`, copied as `.config`. The defconfig path in the script (`defconfig` reduced to `ARCH_TEGRA`/`ARCH_TEGRA_210_SOC`) is only the fallback the config was made from; it does not set options such as `ARM64_PMEM`, which `nvmap` needs. `kernel/build-oot.sh` builds against `/build/linux-$V`. The installed device tree is kept, because the device tree ABI is stable between 6.18.x releases. The configuration contains, among others (see `kernel/build-kernel.sh`):

- `TEGRA210_EMC=y` with a patch that reads the memory timing table from the device tree property `nvidia,emc-table` (`kernel/patches/emc-t210-dt-table.patch`)
- `TEGRA_HOST1X=m`, `DRM_TEGRA=m` with `DRM_TEGRA_STAGING=y` (JetPack's `libnvrm_host1x` needs a `tegra` DRM render node and the staging host1x UAPI), `DRM_NOUVEAU` off
- `VIDEO_TEGRA=m`, `VIDEO_IMX219=m` (camera), `STAGING_MEDIA`
- `IKCONFIG`/`IKCONFIG_PROC`
- the device tree include `kernel/nano-imx219.dtsi` is appended to `tegra210-p3450-0000.dts`: IMX219 on I2C bus 2 address 0x10, reset GPIO, the camera I2C mux fixed to CAM0, CSI A with 2 lanes, 24 MHz fixed clock

The installer additionally patches the compiled DTB (GPU compatible, no `iommus`, EMC table, I2C1), see [install.md](install.md).

## Out-of-tree modules

Built from OE4T `nvidia-kernel-oot` (`wip-r36.5-6.18`) with `kernel/patches/oot-6.18-t210.patch`: `mc-utils`, `host1x-fence`, `nvmap`, `nvgpu` (in `/lib/modules/6.18.62/extra`). The OOT `host1x` and `host1x-nvhost` are not built; `nvgpu` uses the in-tree host1x. `nvgpu` is loaded by `/etc/modules-load.d/nvgpu.conf` (no blacklist, otherwise `systemd-modules-load` refuses it). What the patches do: [gpu-cuda.md](gpu-cuda.md).

## Userspace

- Ubuntu 26.04.1 base, systemd, NetworkManager, OpenSSH, no GUI (about 360 MB RAM idle).
- L4T r36.4 libraries in `/usr/lib/aarch64-linux-gnu/nvidia` (`ld.so.conf.d/nvidia-tegra.conf`), CUDA 12.6 runtime in `/usr/local/cuda-12.6/targets/aarch64-linux/lib`.
- `udev` rules `60-tegra-gpu.rules`: `nvidia-gpu*`, `host1x-fence` and `nvmap` devices get group `video` (0660), `renderD*` group `render`. The default user is in `sudo,video,render,i2c,input`.

## Fake `tegra_fuse` overlay

JetPack's `libnvrm` reads `tegra_fuse` parameters (chip id, revision, platform, prod mode) from `/sys/module/tegra_fuse/parameters`, which mainline does not provide. The service `tegra-fake-fuse` writes the values (chip id 33, revision 2, platform 0, prod mode 1) into `/var/lib/tegra-fake` and mounts a read-only overlay of that directory over `/sys/module`. Side effect: `lsmod` prints errors; `cat /proc/modules` works. Modules loaded after the overlay may not show up in it. A kernel-side solution would replace the overlay.

## Clocks: `tegra-clocks`

A oneshot service sets, at every boot:

- CPUs online (`CPUS=4`) and `scaling_max_freq` of all cores to `CPU_KHZ`, read from `/etc/default/nano-power` (`EnvironmentFile`; installer default 918000; `max` is `cpuinfo_max_freq`, 1555500)
- EMC to 1600 MHz via `/sys/kernel/debug/emc/min_rate` (the table has only 204 and 1600 MHz)

The GPU clock is set by the `nvgpu` module (640 MHz at load, see [gpu-cuda.md](gpu-cuda.md)). EMC and GPU follow the load through `tegra-dvfs.service` (see below). The CPU cap is set with `sudo nano-power safe|max|test|status` (`/usr/local/sbin/nano-power`), which writes `/etc/default/nano-power`: `safe` = 918 MHz, `max` = the highest clock the kernel offers (`cpuinfo_max_freq`, 1555 MHz on the tested board). See [install.md](install.md#cpu-clock-nano-power).

## Other services

`jupyterlab` (port 8888), and with `ROBOT=jetbot` (default `none`): `jetbot-oled`, `jetbot-teleop` (see [robots.md](robots.md)). A 4 GB `/swapfile` with `vm.swappiness=10` is created.

`/etc/update-motd.d/99-jetson-nano` prints the kernel version, the software versions and the `nano-power` mode at login.

## TensorRT: `/opt/nanotrt`

`/opt/nanotrt/lib` holds symlinks to the TensorRT 8.0, cuDNN 8 and CUDA 10.2 libraries of the L4T system (`/media/l4t/...`) and the compiled stubs for `libnvmedia` and `libnvdla_compiler` and `libtrt_shim.so`. `/opt/nanotrt/nanotrt.py` is on the venv path; `/usr/local/bin/nano-trt` is the command line tool. See [tensorrt.md](tensorrt.md).

## Clock scaling (`tegra-dvfs.service`)

`/usr/local/sbin/tegra-dvfs.py` polls the GPU load (`/sys/devices/platform/57000000.gpu/load`) and the busiest CPU core
every 0.25 s. Any load switches to GPU 640 MHz / EMC 1600 MHz at once; after 3 s of idle it drops to GPU 77 MHz (818 mV) and
EMC 204 MHz. While the camera captures (the `host1x_syncpt` interrupt count in `/proc/interrupts` rises), EMC stays at 1600 MHz: an EMC switch during a capture hangs the VI (`MW_ACK_DONE syncpt timeout`, frozen image). EMC is set via `min_rate` and `max_rate` in `/sys/kernel/debug/emc`. The GPU clock is the module parameter
`t210_gpu_mhz`, written through a second sysfs mount (`/run/sysfs-rw`) because `/sys/module` is a read-only overlay
(`tegra-fake-fuse.service`). Settings via environment: `GPU_MAX`, `GPU_IDLE`, `EMC_IDLE`, `HOLD_S`, `CPU_BUSY`.
Stress test: `tools/dvfs-switch-test.py` (random GPU/EMC switching during checked matmuls).
