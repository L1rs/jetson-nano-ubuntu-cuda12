# PyTorch and torchvision

The release contains two wheels for Python 3.14 on aarch64:

- `torch-2.14.1a0+git5c48869-cp314-cp314-linux_aarch64.whl` (CUDA 12.6, sm_53, no cuDNN)
- `torchvision-0.29.2+f122815-py3-none-linux_aarch64.whl` (CUDA ops, no nvjpeg/ffmpeg)

`install.sh` installs them into `~/torch-venv` (created with `--system-site-packages`; the venv installs its own `numpy` 2.5 and `opencv-python-headless` 5.0 from PyPI, plus `onnx` for TensorRT). Version history: numpy 2.3.5 to 2.5.4, OpenCV 4.10 (Ubuntu package) to 5.0 (`opencv-python-headless` 5.0.0.93). v2.14.1 is the last PyTorch release with CUDA 12.6; v2.15 needs CUDA 13 and drops Maxwell. CUDA 12.6 and PyTorch 2.14 are the newest versions that support sm_53.

## How they were built

Build container: Ubuntu 26.04 arm64 with 10 CPUs and 12 GB RAM (6 GB was not enough: it thrashed and hung the VM), Python 3.14, gcc-13, and the **CUDA 12.6 toolkit from the Jetson apt repository** (`pytorch/pb-setup.sh`). Scripts are in `pytorch/` and expect the original container paths (`/work`, `/w`); read and adapt them.

Key settings (`pytorch/run.sh`):

- `TORCH_CUDA_ARCH_LIST=5.3`, `USE_CUDA=1`. `run.sh` defaults to `USE_CUDNN=0` like the published wheel; set `USE_CUDNN=1` to reproduce the cuDNN experiment (see below).
- `USE_CPU_VECTORIZATION=0`: the Cortex-A57 has no SVE, and PyTorch's codegen otherwise builds SVE variants. This is an existing environment variable, no patch needed.
- `USE_NCCL=0 USE_DISTRIBUTED=0 USE_MKLDNN=0 USE_FBGEMM=0 USE_KINETO=0 USE_FLASH_ATTENTION=0 USE_MEM_EFF_ATTENTION=0 BLAS=OpenBLAS`
- Shallow, non-recursive clone with only the needed submodules (the full recursive clone hangs; some submodules are gigabytes).
- `python -m build --wheel --no-isolation` (`setup.py bdist_wheel` no longer exists in 2.14).
- glibc 2.43 collides with the CUDA 12.6 headers: `rsqrt`, `sinpi`, `cospi` declarations need `noexcept(true)` in `crt/math_functions.h` (a `sed` in `pb-setup.sh`).
- **Out-of-memory protection:** some generated ATen files (`Register*`, `Operators_*`) need about 3.6 GB per compiler process, and several CUDA/CUTLASS files and torch_python bindings are also huge. `pytorch/pool-cuda.py` adds `pool = heavy` (depth 1) to those edges in `build.ninja`, and `MAX_JOBS` is kept low (5-6) for the rest.
- torchvision (`pytorch/vision.sh`): tag v0.29.2, `FORCE_CUDA=1`, `TORCH_CUDA_ARCH_LIST=5.3`, nvjpeg/ffmpeg off; about 1 minute.

Hints: the torch build needs roughly 5-6 GB for sources and build tree plus the CUDA toolkit, and takes hours (the cuDNN rebuild was estimated at "about 2 h+"; the first full build time was not recorded). The CUDA samples (`deviceQuery`, `bandwidthTest`, from cuda-samples v12.5) are built with `pytorch/build-cuda-samples.sh`.

## cuDNN finding

cuDNN 9.3.0.75 (Jetson r36.4) **does contain sm_53 code**, and a PyTorch build with `USE_CUDNN=1` works with identical output (max difference 0.0). But it is **slower** on the Nano (resnet18, batch 1):

| | FP16 | FP32 |
|---|---|---|
| without cuDNN | 18.2 fps | 15.4 fps |
| with cuDNN | 15.0 fps | 13.7 fps |

`cudnn.benchmark=True` did not help. So the published wheel is built without cuDNN. Other attempts that did not help: `channels_last`, `torch.jit.trace`, `optimize_for_inference`, CUDA graphs. 160x160 input reaches 34 fps but changes the road-following output too much for the existing model (mean deviation 0.76), so it was discarded. The GPU is the bottleneck.

## Benchmark

`tools/bench.py` prints matmul GFLOPS, resnet18 fps for FP16/FP32 (and with cuDNN if available) and a numpy CPU matmul. Run it with `~/torch-venv/bin/python tools/bench.py`. Results: [benchmarks.md](benchmarks.md).
