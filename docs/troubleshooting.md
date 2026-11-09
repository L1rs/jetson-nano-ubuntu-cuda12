# Troubleshooting

## The Nano hangs or reboots under load (brownout)

Symptom: sudden freeze, no kernel log, sometimes SError / PMU errors, usually when CPU and GPU are both busy. Cause: weak 5 V supply or cable. Keep the CPU in safe mode (`sudo nano-power safe`, 918 MHz) with micro-USB, or use a strong supply such as a 5 V/4 A barrel jack supply or the Waveshare JetBot battery board. Measurements: [benchmarks.md](benchmarks.md#power-supply-tests).

**Raising the CPU cap:** run `sudo nano-power test`. It loads CPU (3 cores) and GPU for 5 minutes at the maximum clock (1555 MHz) and saves `max` only if that passes. `sudo nano-power safe|max` set the mode without a test; `nano-power status` shows it. The setting is stored in `/etc/default/nano-power` and read by `tegra-clocks.service`. If the Nano hangs during the test, power-cycle it: it boots in the previous mode. The log is `/var/log/nano-power-test.log`. More: [install.md](install.md#cpu-clock-nano-power).

## GPU errors after max clocks (`0xbad00100`, cuBLAS allocation failure)

Symptom: after running at `max` on a weak supply, CUDA calls fail, cuBLAS cannot allocate memory, or the GPU registers read `0xbad00100`. Cause: a voltage dip made the GPU firmware fail. `nano-power test` detects this case: it prints `FAILED`, keeps the previous mode and recommends a reboot. Reboot (the GPU stays in a bad state until then) and stay in `safe` mode, or use a stronger supply.

## The Nano hangs during a TensorRT engine build

Cause: TensorRT times kernel candidates, and some run longer than the 7 s nvgpu watchdog. The watchdog recovery in this nvgpu port leaves the GPU in a bad state (PRI timeouts, PMU DMEM errors) and then hangs the Nano. Build engines only with `sudo nano-trt build`, which switches the watchdog off (`/sys/kernel/debug/gpu.0/timeouts_enabled`) and on again afterwards. Power-cycle after a hang. Other TensorRT errors (`importConv`, `libcublas.so.10`): [tensorrt.md](tensorrt.md#troubleshooting).

## USB does not work

`tegra-xusb` is built into the kernel and needs `nvidia/tegra210/xusb.bin` in the initramfs (`/boot/mainline/initrd-u2604.img`). The installer handles it. If you rebuilt the initramfs, add `lib/firmware/nvidia/tegra210/xusb.bin` (from L4T `/lib/firmware`). Check with `lsusb` and `dmesg | grep -i xusb`.

## Gamepad does nothing, or the sticks only give 0 / full deflection

Use the PC mode of the pad with two LEDs lit. Xbox mode needs `xpad`, which is not built. Check events with `~/jetbot/teleop.py --probe` (stop the service first: `sudo systemctl stop jetbot-teleop`). Teleop is intentionally paused while a notebook holds `/dev/shm/jetbot-notebook`; stop the notebook kernel to release it.

## `scp` hangs

Seen from some clients, even with `openssh-sftp-server` installed; the cause is not investigated. Alternatives: `rsync -e ssh`, `ssh jetson@<jetson-ip> 'cat > file' < file`, or serve the file from your computer with `python3 -m http.server --bind <your-ip>` and fetch it on the Nano with `curl` or Python `urllib`.

## `lsmod` prints errors

Caused by the fake `tegra_fuse` overlay on `/sys/module`. Use `cat /proc/modules`.

## `gpcclk/clk_rate` shows 217.6 MHz

Stale value. The real GPU clock is 640 MHz; see `dmesg | grep vdd-gpu`. `tegra-dvfs.service` sets it by load; see gpu-cuda.md for setting it by hand.

## `nvgpu` cannot be reloaded

`rmmod nvgpu` fails or hangs. Reboot.

## Camera shows no image or wrong colours

Check `ls /dev/video0` and `v4l2-ctl --list-formats-ext`. One `frame start syncpt timeout` at stream start is normal. Colours uncorrected: `/opt/nanocam/camera_overrides.isp` is missing (it is copied from L4T, see [camera.md](camera.md)).

## Cannot reach the Nano after boot

Wait about 40 s after a cold start. The WLAN profiles are copied from the L4T system; Ethernet uses DHCP. With a serial console (115200 8N1) you can watch the boot. Selecting a boot entry is possible only over the serial console; otherwise edit `DEFAULT` in `extlinux.conf` from another computer or from the other system. The L4T entry is `primary`.

## `pip`/PyTorch problems

Use the venv: `~/torch-venv/bin/python`. Python 3.14 wheels are needed; the PyTorch wheel is for `cp314` only.

## Updating safely

`sudo apt update && sudo apt upgrade` is fine. The installer pins packages that would break the system
(`/etc/apt/preferences.d/jetson-nano-protect`: kernels, bootloaders, NVIDIA desktop drivers, L4T packages, Ubuntu's CUDA 13)
and fixes torch/torchvision in the venv (`~/torch-venv/pip.conf` + `constraints.txt`). Do **not**:

- run `do-release-upgrade` (a newer Python breaks the cp314 torch wheel and the venv),
- install PyTorch from PyPI (built for CUDA 13 / newer GPUs, does not run on sm_53),
- run `apt upgrade` in the old L4T system: NVIDIA's bootloader/kernel packages may rewrite `/boot/extlinux/extlinux.conf`
  (fix: set `DEFAULT u2604` again),
- change or delete files in `/media/l4t/boot` or `/opt/u2604` on the L4T partition (that *is* the running system).
