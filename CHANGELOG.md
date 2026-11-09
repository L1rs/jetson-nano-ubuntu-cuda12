# Changelog

## v0.2.0 (2026-11-09)

- Repository name: `L1rs/jetson-nano-ubuntu-cuda12` (version independent; was `jetson-nano-ubuntu-26.04-cuda12`). `SLUG` default, clone URLs, `nano-update` and docs use it.
- `update.sh` rewritten: downloads and verifies first, then adds missing Ubuntu packages and CUDA runtime, new PyTorch wheels (pin moves along) and missing Python packages, system fixes, tools, robot code, kernel; version written last; log `/var/log/nano-update.log`, `ERROR in update step N` with rerun hint. Package lists moved to `rootfs/packages.txt`, `rootfs/cuda-packages.txt`, `rootfs/venv-requirements.txt` (shared by installer and update). `nano-update install`: lock against parallel runs, checks the download. Tested with a simulated release, including an aborted and repeated update.
- Ready-made SD card image (`image/`): `clean-for-image.sh` removes device data and arms the one-time first boot; `firstboot.sh` grows the partition to the card, creates new SSH keys and writes the board's own trained RAM timing table into the Ubuntu 26.04 device tree, then boots Ubuntu 26.04. `read-card-macos.sh`, `shrink-image.sh` (minimal file system, zeroed free blocks, same PARTUUID, `.img.xz`), `flash-image-macos.sh`. v0.2.0 image: 6.7 GB download, needs a 32 GB card; tested by flashing and booting. See [docs/image.md](docs/image.md).
- Test install on a fresh NVIDIA JetPack 4.6.1 card (L4T 32.7.1) found and fixed five problems:
  - EMC table: L4T 32.7.1 lists the trained tables in descending order (1600, 204 MHz), the mainline driver rejects that (`-22`, no memory clock scaling). `kernel/emc-table.py` sorts them.
  - Ethernet stayed down: Ubuntu's NetworkManager leaves ethernet unmanaged without netplan. `build-rootfs.sh` overrides `10-globally-managed-devices.conf`. Note: Ubuntu 26.04 gets a different DHCP address than L4T.
  - PyTorch import failed: `libopenblas0` and `libnvjitlink-12-6` added to `build-rootfs.sh`.
  - A freeze during the install (L4T in MAXN on a weak supply) left empty files in the venv, and a rerun kept them. `install.sh` now syncs after every step and rebuilds the venv on a rerun.
  - More robust installer: checks clock, internet and release URL first; waits for a running apt; 5 W power mode while installing (restored at the end); full log in `/var/log/jetson-nano-install.log`, keeps running when SSH drops; `ERROR in step N` with a rerun hint; import self-test of the Python environment; `build-rootfs.sh` repairs an interrupted dpkg, retries downloads, stops on a missing CUDA runtime; avahi for `ssh jetson@jetson.local`.
  - Verified: second fresh JetPack 4.6.1 card, `sudo ./install.sh -y` ran through without manual steps in 16 minutes; after the reboot all services run, EMC 204/1600 MHz, CUDA, JupyterLab, camera, TensorRT (66.9 fps) ok, reachable as `jetson.local`.
  - TensorRT on JetPack 4.6.1 is 8.2.1 (not 8.0): works the same, resnet18 FP16 66.6 fps, 0.2 % deviation from PyTorch.

- Update check: `VERSION` file, `/etc/jetson-nano-version`, `nano-update` (show / install / check), daily `nano-update.timer` with a note at login, `update.sh` that brings an installed system to the state of a release (tools, TensorRT bridge, robot code, new notebooks, new kernel with fallback entry `u2604-prev`). See docs/updates.md.

- Prerequisites defined: L4T 32.6/32.7 (JetPack 4.6.x) required, installer checks the L4T revision; supported starting images and download links in docs/install.md. `cpio` added to the host tools.

- Installer rewritten for transparency. It shows what it changes and where the files come from, asks four questions with explanations and the password, shows a settings summary and asks `Start the installation? [Y/n]`. `sudo ./install.sh --plan` only shows the overview and the settings and changes nothing. `sudo ./install.sh -y` asks nothing and uses the defaults or environment variables. The checks run before the questions. Ten numbered steps.
- `ROBOT` now defaults to `none` (was `jetbot`). `jetbot` starts the OLED and gamepad services.
- The update lock is optional: `UPDATE_LOCK=1` (default) or `0`. The login message says whether it is on.
- `POWER=safe|max` replaces `CPU_KHZ` as an `install.sh` option (`build-rootfs.sh` still takes `CPU_KHZ`).
- CPU clock correction: the mainline kernel offers at most 1555.5 MHz on this board. The earlier value 1912500 was silently capped, so all "1912 MHz" measurements ran at up to 1555 MHz. `nano-power max` now reads the highest clock from the kernel (`cpuinfo_max_freq`). The docs say 1555 MHz now.
- `nano-power test` was run on the Waveshare JetBot battery board: 5 minutes of full CPU and GPU load at max passed and max was saved. A short test on a micro-USB supply had failed with GPU firmware errors, which the test detected.
- Benchmarks repeated at max CPU clock on the battery board: CPU work is faster (numpy matmul 23.1 to 31.8 GFLOPS), GPU results are unchanged. See [docs/benchmarks.md](docs/benchmarks.md#cpu-clock-and-gpu-results).
- cuBLAS gap versus L4T investigated; many causes ruled out, still open. See [docs/benchmarks.md](docs/benchmarks.md#open-cublas-gemm-per-clock).
- Screenshots in `docs/img/` (installer, login, TensorRT, JupyterLab), shown in the README.
- JetBot notebook comments are English now.
- The old kernel asset `linux-6.18-...` was removed from `dist/`; only 6.18.62 remains.
- Kernel updated from 6.18.0 to 6.18.62 (longterm). Release asset `linux-6.18.62-t210-jetson-nano.tar.gz`, modules in `/lib/modules/6.18.62`. `kernel/build-kernel.sh` uses `V=${V:-6.18.62}` and the tested configuration `kernel/config-6.18-t210`; `kernel/build-oot.sh` builds against `/build/linux-$V`. The installed device tree is kept. Benchmarks unchanged.
- `nano-power` (`sudo nano-power safe|max|test|status`): CPU clock cap 918 MHz (safe, default) or the highest clock the kernel offers, 1555 MHz (max). `test` runs 5 minutes of CPU and GPU load and saves `max` only if it passes. The setting is in `/etc/default/nano-power`, read by `tegra-clocks.service`. The login message shows the mode. Replaces editing the `tegra-clocks.service` file.
- TensorRT 8.0 works, using the TensorRT, cuDNN and CUDA 10.2 libraries of the user's own L4T install (nothing redistributed): `tensorrt/` with `build.sh`, `nano-trt`, `nanotrt.py`, `trt_shim.cpp` and DLA stubs. New docs: [docs/tensorrt.md](docs/tensorrt.md). `nano-trt build` switches the GPU watchdog off during the build, which fixes the freezes of engine builds. resnet18 FP16: 67.1 fps (PyTorch 18.2 fps).
- `jetbot.ObjectDetector` uses a TensorRT engine if `~/jetbot/ssdlite320.engine` exists (`~/jetbot/build_detector.sh`). Postprocessing rewritten (top 200 and one `batched_nms`). At CPU 918 MHz, 300x300: 5.4 fps before, 12.1 fps in PyTorch, 16.7 fps with TensorRT.
- JetBot notebooks: alexnet replaced by resnet18 in `collision_avoidance` and `object_following`, `weights='DEFAULT'/None` instead of `pretrained`, `torch.load` with `map_location='cpu'`. Models trained with the old AlexNet notebooks must be retrained.
- Package updates: numpy 2.3.5 to 2.5.4, OpenCV 4.10 (Ubuntu package) to 5.0 (`opencv-python-headless` 5.0.0.93 in the venv), Donkeycar 5.0.0 to 5.4.0 (docs). `onnx` added to the venv.
- Comparison with NVIDIA L4T R32.6.1 on the same board in [docs/benchmarks.md](docs/benchmarks.md#comparison-with-nvidia-l4t). New tools: `tools/l4t-compare.sh`, `tools/bench_cmp.py`, `tools/gpuclk.py`.
- `tegra-dvfs` service: GPU/EMC clock scaling by load (switching tested under load).
- `jetbot.ObjectDetector`: PyTorch SSDlite replacement for the TensorRT detector; `object_following` notebook added.
- Installer protects the system against careless updates (apt pins, pip constraints, L4T package hold).

## v0.1.0 (2026-11-08)

First public version. **Experimental:** `install.sh` automates steps that were each done and verified by hand on one board, but has not yet been tested end-to-end on a fresh card.

- Ubuntu 26.04.1 on mainline Linux 6.18 for the Jetson Nano 4 GB, booted through an extlinux entry and a small initramfs from a directory of the L4T partition
- GM20B GPU with nvgpu (OE4T R36.5 sources, patched), fixed 640 MHz, EMC 1600 MHz
- CUDA 12.6 (JetPack 6 userspace), PyTorch 2.14.1 and torchvision 0.29.2 wheels for Python 3.14 / sm_53 (no cuDNN)
- IMX219 camera with colour (`nanocam`)
- Waveshare JetBot support (motors, OLED, battery, gamepad, notebooks) and JetRacer helpers
- Release assets: kernel archive, torch and torchvision wheels, `SHA256SUMS`
