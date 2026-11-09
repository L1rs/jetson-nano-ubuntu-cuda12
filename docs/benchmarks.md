# Benchmarks

Board: Jetson Nano 4 GB, GPU 640 MHz / 928 mV, EMC 1600 MHz, stable power. PyTorch 2.14.1 without cuDNN unless noted. Script: `tools/bench.py`. Kernel Linux 6.18.62 (updated from 6.18.0 on 2026-11-09; all benchmarks were unchanged after the update).

## GPU compute

| Test | Result |
|---|---|
| matmul 2048x2048 FP32 | 134 GFLOPS (peak 164 GFLOPS) |
| matmul 2048x2048 FP16 | 119 GFLOPS |
| numpy CPU matmul 1024x1024 FP32 | 39 GFLOPS |
| GPU clock scaling (FMA loop) | 217.6 MHz 472.8 ms; 614 MHz 167.1 ms; 640 MHz 160.5 ms (2.95x) |

## Memory (bandwidthTest, CUDA 12.6)

| EMC | H2D | D2H | D2D |
|---|---|---|---|
| 204 MHz | 1.2 GB/s | 1.2 GB/s | 2.3 GB/s |
| 1600 MHz | 8.9 GB/s | 9.0 GB/s | 15.4 GB/s |

`deviceQuery` passes with CUDA 12.6 / 12.6, compute capability 5.3, 1 SM.

## Neural network inference (resnet18, 224x224, batch 1)

| Build | FP16 | FP32 |
|---|---|---|
| without cuDNN | 18.2 fps | 15.4 fps |
| with cuDNN 9.3 | 15.0 fps | 13.7 fps |

With cuDNN, `cudnn.benchmark=True` did not help. Further FP16 variants (without cuDNN): `channels_last` 15.4 fps, `jit.trace` 18.2, `optimize_for_inference` 18.4, CUDA graph 18.1, 160x160 input 34 fps and 128x128 49 fps (output deviates too much from the 224x224 model).

AlexNet (pretrained weights loaded; the JetBot notebooks use resnet18 now): training 0.84 s per batch of 8, inference 26.9 fps.

## TensorRT 8.0 (FP16, batch 1, GPU 640 MHz)

TensorRT 8.0.1 from the L4T libraries, see [tensorrt.md](tensorrt.md).

| Model | TensorRT | PyTorch FP16 | Factor |
|---|---|---|---|
| resnet18, 224x224 | 67.1 fps (67.6 fps from Python via `TRTModule`) | 18.2 fps | 3.7x |
| resnet50, 224x224 | 24.8 fps | 8.7 fps | 2.8x |

For resnet18 FP16 the maximum absolute difference to the FP32 PyTorch output is 0.014 (logits up to 5.9), with the same argmax. Engine build times: resnet18 about 125 s, resnet50 about 285 s, SSDlite320 about 670 s.

## Object detection (SSDlite320-MobileNetV3, 300x300 input)

Measured at CPU 918 MHz (`nano-power safe`). The postprocessing runs on the CPU and was the main bottleneck.

| Path | fps |
|---|---|
| old PyTorch path (torchvision per-class loop over 90 classes) | 5.4 |
| new PyTorch FP16 path (top 200 over anchors x classes, one `batched_nms`) | 12.1 |
| TensorRT FP16 | 16.7 (17.4 with the live camera) |

On a test image the result is the same: a dog (label 18) with confidence 0.82 in TensorRT and 0.83 in PyTorch, identical box. Earlier versions of these docs gave 8.8 fps (6.8 fps with live camera); that was the old code at the highest CPU clock (requested as 1912 MHz; the kernel caps requests at 1555 MHz).

## Road following (`jetracer/road_following.py`)

Camera + preprocessing + resnet18 FP16: 11.9 fps with the camera read in the main loop, **17.3 fps** with the camera in its own thread (120 s run, 2071 frames, same at 918 MHz and at max CPU clock (1555 MHz; the kernel caps requests at 1555 MHz, earlier docs said 1912 MHz): the GPU is the bottleneck).

## Camera

30 fps at 224x224 and 640x480 (sensor at 30 fps); raw capture 60 fps at 1640x1232.

## Power supply tests

GPU load: matmul on the GPU (640 MHz, 928 mV) plus CPU load on 4 cores, EMC 1600 MHz. Script: `tools/psu-test.sh`.

| Power source | CPU limit | Result |
|---|---|---|
| micro-USB | 918 MHz x 4 | stable (EMC + GPU loop + memtester for 10 min with 2 cores, 5 min with 4 cores, up to about 8 W) |
| micro-USB | 1224 MHz | CPU only, 10 min: ok. With GPU load: crash after less than 20 s |
| micro-USB | 1428 MHz | crash under CPU + GPU load after about 60 s |
| micro-USB | 1428 MHz or more, 4 cores, EMC 1600 | hang under load (SError, PMU error) |
| Waveshare JetBot battery board (3 x 18650) | 918, 1428 MHz, max (1555 MHz), 5 min each | no crash, maximum about 45 C |

Conclusion: with micro-USB keep the CPU at 918 MHz (`nano-power safe`, installer default); with a strong supply use `sudo nano-power test`, which checks the maximum clock (1555 MHz) under CPU and GPU load for 5 minutes before it saves `max`. In one run a short test at max on a micro-USB supply made the GPU firmware fail (registers read 0xbad00100, cuBLAS allocation failure) without a full hang. This is a voltage dip, and it is the case the test detects. A cuDNN benchmark run also crashed the Nano on the weak supply, probably a voltage dip. A barrel-jack supply did not boot through in one test and was set aside.

`sudo nano-power test` was run for real on the Waveshare JetBot battery board: 5 minutes of full CPU and GPU load at max passed and max was saved. The short test on the micro-USB supply that failed (GPU firmware errors) was detected by the test.

Note: the kernel offers at most 1555.5 MHz on this board (`cpuinfo_max_freq` 1555500; steps up to 1479000 and 1555500, no boost). The value 1912500 used earlier was silently capped, so earlier "1912 MHz" measurements ran at up to 1555 MHz. Docs now say 1555 MHz.

## Comparison with NVIDIA L4T

The same board was measured under NVIDIA's original system and under this project, 2026-11-09, on a micro-USB supply.

- L4T: R32.6.1 (JetPack 4.6, Qengineering Ubuntu 20.04 image), kernel 4.9.253, CUDA 10.2, cuDNN 8.2, PyTorch 1.13 for Python 3.8.
- This project: Ubuntu 26.04, kernel 6.18.62, CUDA 12.6 driver, PyTorch 2.14 without cuDNN.

**Clocks.** As equal as possible: CPU at most 918 MHz, EMC 1600 MHz. GPU 640 MHz here and 614.4 MHz on L4T, which has no 640 MHz step (the next steps are 614.4 and 691.2 MHz). The real SM clock was measured with a `%clock64` PTX kernel against wall time (`tools/gpuclk.py`): 640.1 MHz here and 614.5 MHz on L4T.

**Method.** Same binaries where possible. `bandwidthTest` and `matrixMulCUBLAS` were built once with the L4T CUDA 10.2 toolchain and run on both systems. TensorRT used identical engine files. PyTorch was measured with `tools/bench_cmp.py`. Everything runs from `tools/l4t-compare.sh`.

| Test | L4T (614.4 MHz) | This project (640 MHz) |
|---|---|---|
| bandwidthTest H2D / D2H / D2D | 8.6 / 8.6 / 15.1 GB/s | 9.0 / 9.0 / 15.6 GB/s |
| matrixMulCUBLAS (cuBLAS 10, same binary) | 119.2 GFLOPS | 108.5 GFLOPS |
| TensorRT 8.0 FP16 resnet18 | 64.0 qps | 67.1 qps |
| TensorRT 8.0 FP16 resnet50 | 23.7 qps | 24.6 qps |
| TensorRT 8.0 FP16 SSDlite320 core | 20.0 qps | 21.0 qps |
| PyTorch matmul 2048 FP16 / FP32 | 142 / 149 GFLOPS | 119 / 134 GFLOPS |
| PyTorch resnet18 FP16 | 15.4 fps (cuDNN), 11.1 fps (no cuDNN) | 18.2 fps |
| PyTorch resnet18 FP32 | 24.4 fps (cuDNN), 13.1 fps (no cuDNN) | 15.3 fps |
| PyTorch resnet50 FP16 | 6.9 fps (cuDNN), 6.5 fps (no cuDNN) | 8.7 fps |
| PyTorch resnet50 FP32 | 8.5 fps (cuDNN), 7.3 fps (no cuDNN) | 7.7 fps |

L4T used PyTorch 1.13 with cuDNN 8.2, switched on and off. This project has no cuDNN.

The cuBLAS gap is investigated below: [Open: cuBLAS GEMM per clock](#open-cublas-gemm-per-clock).

**Result.**

- With TensorRT the new system is as fast as L4T per clock (the TensorRT results are the same per clock).
- Plain PyTorch is faster in FP16 here. L4T is faster in FP32 because of cuDNN 8.
- cuBLAS GEMM is 10 to 13 % slower per clock here. The cause is not found yet; this is an open point. The real GPU clock was verified. The L2/LTC debugfs switch shows N, but toggling it changes nothing; it is only not initialised in this build.
- With L4T's default clocks (GPU up to 921.6 MHz) L4T is faster in absolute terms. On a micro-USB supply those clocks hung L4T in the first attempt.

## CPU clock and GPU results

Repeated at the maximum CPU clock (1555 MHz; the kernel caps requests at 1555 MHz, earlier docs said 1912 MHz) on the Waveshare JetBot battery board. Compared with CPU 918 MHz:

| Test | 918 MHz | 1555 MHz |
|---|---|---|
| numpy CPU matmul | 23.1 GFLOPS | 31.8 GFLOPS (+38 %) |
| PyTorch matmul FP16 / FP32 | 119 / 134 GFLOPS | 119 / 137 GFLOPS |
| resnet18 FP16 / FP32 | 18.2 / 15.4 fps | 18.2 / 15.4 fps |
| Object detector, live camera, TensorRT | 17.4 fps | 17.4 fps |
| Object detector, PyTorch | 12.1 fps (test image) | 12.4 fps (live camera) |

Conclusion: the CPU clock matters only for CPU work. GPU results do not depend on it.

## Open: cuBLAS GEMM per clock

`matrixMulCUBLAS` (the same CUDA 10.2 binary) is about 13 % slower per clock here than on L4T. TensorRT engines are equal per clock, so the difference is specific to cuBLAS GEMM. Ruled out so far:

| Suspect | Evidence |
|---|---|
| Real SM clock | PTX `%clock64` against wall time: 640.1 MHz here, 614.5 MHz on L4T |
| GPU page size | nvmap hands out 64 KB chunks (234240 of 234254 page allocations). CUDA allocations sit in the big-page VA region. gm20b uses split address spaces, so big pages are used without IOMMU |
| L2 cache | debugfs `ltc_enabled` shows N only because the flag is not initialised in this build. Toggling it changes nothing |
| Memory controller arbitration, EMC timing | MC/EMC register dump under GPU load on both systems via `/dev/mem`: arbitration identical; EMC differs only in per-boot training trims; MC differs in SMMU registers |
| GPU read latency allowance | MC register 0x3c8: 0x1e on L4T, 0x50 here. Setting 0x1e changed nothing |
| Device properties seen by CUDA | `deviceQuery` of the same CUDA 10.2 binary: L2 256 KB, 1 SM, 13 MHz memory clock, same as L4T |
| GPU clock and power gating | ELPG, AELPG, ELCG, BLCG, SLCG switched off: no change |

Remaining suspect: the GPU-internal configuration of the newer nvgpu (R36.5) compared with L4T's R32 driver. Next step: compare the GPU registers of both systems.
