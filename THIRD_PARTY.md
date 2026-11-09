# Third-party components

## Not redistributed (downloaded by the installer from the original source)

| Component | Source | Note |
|---|---|---|
| NVIDIA L4T r36.4 packages `nvidia-l4t-core`, `nvidia-l4t-cuda`, `nvidia-l4t-3d-core` (libcuda, libnvrm, ptxjitcompiler, ...) | `repo.download.nvidia.com` | NVIDIA license; downloaded onto your device |
| CUDA 12.6 runtime libraries (cudart, cuBLAS, cuFFT, cuRAND, cuSOLVER, cuSPARSE, NVRTC, cuFile) | NVIDIA Jetson apt repository | NVIDIA license |
| GM20B GPU firmware (`/lib/firmware/gm20b`, `nvidia/tegra210/xusb.bin`) | your own L4T install (`/lib/firmware`) | NVIDIA license; copied locally by the installer |
| `camera_overrides.isp` (lens shading and colour matrix) | your own L4T install (`/var/nvidia/nvcam/settings`) | copied locally by the installer; not in this repository |
| Ubuntu 26.04 base and packages | `cdimage.ubuntu.com`, Ubuntu archive | various free licenses |
| JetPack 4.6 SD card image | NVIDIA | you flash it yourself |
| TensorRT 8.0.1, cuDNN 8.2, CUDA 10.2 libraries (`libnvinfer`, `libnvonnxparser`, `libcudnn`, `libcublas` 10, ...) | your own L4T install on the same card (`/media/l4t`) | NVIDIA license; used at run time through symlinks in `/opt/nanotrt/lib`, not copied, not redistributed. The TensorRT headers and the g++ 7 toolchain of L4T compile the stubs and `trt_shim` locally. |
| `onnx` | PyPI | Apache-2.0; installed into the venv |
| `opencv-python-headless` 5.0 | PyPI | Apache-2.0; installed into the venv |
| `numpy` 2.5 | PyPI | BSD-3-Clause; installed into the venv |

The own stubs (`tensorrt/nvmedia-stub.c`, `tensorrt/nvdla-stub.c`) and `tensorrt/trt_shim.cpp` contain no NVIDIA code. The PyTorch wheels in the release do not contain NVIDIA libraries; they link to the CUDA libraries installed from NVIDIA's repository.

## Included in this repository or in the release

| Component | License | Where |
|---|---|---|
| Own scripts, documentation, `jetbot/` and `jetracer/` code | MIT | `LICENSE` |
| `kernel/patches/` (patches to Linux and to the OE4T nvidia-oot / nvgpu sources) | GPL-2.0 | `kernel/patches/LICENSE` |
| JetBot notebooks (derived from NVIDIA/Waveshare JetBot) | MIT, (c) 2019 NVIDIA CORPORATION | `jetbot/notebooks/LICENSE-jetbot.md` |
| `jetracer/` replacements for NVIDIA's JetRacer / jetcam classes | MIT (API-compatible rewrites); `jetracer/racecar.py` is NVIDIA's original, MIT, Copyright (c) 2019 NVIDIA CORPORATION | `LICENSE` |

## Release assets

- `linux-6.18.62-t210-jetson-nano.tar.gz`: **GPL-2.0.** Contains a mainline Linux 6.18.62 `Image` and device tree, kernel modules, and the out-of-tree modules `nvgpu`, `nvmap`, `host1x-fence`, `mc-utils`. Sources: mainline Linux v6.18.62 plus `kernel/patches/`, the kernel configuration `kernel/config-6.18-t210` (and the device tree include `kernel/nano-imx219.dtsi`), and the OE4T `nvidia-kernel-oot` branch `wip-r36.5-6.18` (with its `nvgpu` / `nvidia-oot` submodules). The exact sources and configuration are in `kernel/build-*.sh`.
- `torch-2.14.1a0+git5c48869-cp314-cp314-linux_aarch64.whl`: PyTorch, BSD-3-Clause-style license. Built from tag v2.14.1 (see `pytorch/run.sh`).
- `torchvision-0.29.2+f122815-py3-none-linux_aarch64.whl`: torchvision, BSD-3-Clause. Built from tag v0.29.2.
- `SHA256SUMS`: checksums of the three files.

## Ready-made SD card image (not part of the repository or the GitHub release)

The image (`jetson-nano-ubuntu-26.04-v<VERSION>.img.xz`, hosted on Google Drive, see the README) is a copy of an SD card with NVIDIA's JetPack 4.6.1 SD card image after `install.sh`. Besides the components above it therefore **contains** NVIDIA software, unchanged: L4T 32.7.1 with CUDA 10.2, cuDNN 8 and TensorRT 8.2 (license texts in `/usr/share/doc/nvidia-tegra/` of the L4T system), and in Ubuntu 26.04 the L4T r36.4 userspace and the CUDA 12.6 runtime packages listed above. These remain under NVIDIA's license terms. The image is unofficial and not provided or supported by NVIDIA. `install.sh` remains the way to get the same system without downloading NVIDIA software from a third party.

## Projects this work builds on

OE4T `nvidia-kernel-oot` and `linux-nvgpu` (NVIDIA R36.5 sources, GPL-2.0 / MIT in parts), the Linux kernel, NVIDIA JetPack / L4T, PyTorch, torchvision, NVIDIA cuda-samples v12.5 (used for `deviceQuery` / `bandwidthTest`), Waveshare and NVIDIA JetBot / JetRacer, OpenCV, ONNX, JupyterLab. Donkeycar is not installed by the installer; `jetracer/donkey-nano_parts.py` only provides parts for it (tested with Donkeycar 5.4.0).
