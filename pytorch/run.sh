#!/bin/bash
# UNGETESTET (Abbruch wegen Mac-Plattenplatz < 4 GB). Läuft im Container pb (ubuntu:26.04, Python 3.14) nach tools/pb-setup.sh.
# Version: PyTorch v2.14.1 (letzte Version mit CUDA 12.6 laut RELEASE.md; v2.15 braucht CUDA 13; cmake/public/cuda.cmake fordert >= 12.6). Python 3.14 wird bis 2.14 unterstützt.
# Benötigt ca. 5-6 GB freien Platz für Quellen + Build; auf dem Host mindestens 12 GB frei halten.
set -e
export PATH=/usr/local/cuda-12.6/bin:$PATH CUDA_HOME=/usr/local/cuda-12.6
mkdir -p /work /w/torch; cd /work
[ -d pytorch ] || git clone --depth 1 -b v2.14.1 https://github.com/pytorch/pytorch
cd pytorch
# Nicht rekursiv und ohne ROCm/FlashAttn-Submodule (composable_kernel/aiter/mslk/fbgemm: GB-gross, haengt beim Clonen)
find .git -name '*.lock' -delete
git submodule update --init --depth 1 -j6 third_party/{pybind11,protobuf,sleef,onnx,psimd,pthreadpool,nlohmann,pocketfft,tensorpipe,cutlass,kineto,fmt,cpuinfo,XNNPACK,FP16,FXdiv,NVTX,googletest,benchmark,flatbuffers,ittapi,gloo,python-peachpy,VulkanMemoryAllocator,cudnn_frontend,ideep,kleidiai,gemmlowp/gemmlowp,mimalloc,cpp-httplib,NNPACK}
git submodule foreach -q "git checkout -f HEAD" >/dev/null 2>&1 || true  # psimd kam leer aus dem shallow update
python3 -m venv --system-site-packages /work/venv && . /work/venv/bin/activate
pip install -q -r requirements.txt wheel
export CC=gcc-13 CXX=g++-13 CUDAHOSTCXX=g++-13
# Cortex-A57 hat kein SVE: cmake/Codegen.cmake baut sonst *.SVE128/SVE256-Varianten (ohne Patch abschaltbar)
export USE_CPU_VECTORIZATION=0
export TORCH_CUDA_ARCH_LIST="5.3" MAX_JOBS=${MAX_JOBS:-6} CMAKE_BUILD_TYPE=Release
export USE_CUDA=1 USE_CUDNN=${USE_CUDNN:-0} CUDNN_INCLUDE_PATH=/usr/include CUDNN_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu USE_NCCL=0 USE_DISTRIBUTED=0 USE_MKLDNN=0 USE_FBGEMM=0 USE_KINETO=0 \
       BUILD_TEST=0 USE_NNPACK=0 USE_QNNPACK=0 USE_PYTORCH_QNNPACK=0 USE_XNNPACK=1 USE_FLASH_ATTENTION=0 \
       USE_MEM_EFF_ATTENTION=0 USE_ROCM=0 USE_NUMA=0 USE_SYSTEM_NCCL=0 BLAS=OpenBLAS
# cuDNN 9.3.0.75 (Jetson-Repo r36.4: libcudnn9-cuda-12 + libcudnn9-dev-cuda-12, in pb installiert) hat sm_53-Kerne (verifiziert) -> baubar mit USE_CUDNN=1, aber auf sm_53 langsamer (15,0 statt 18,2 fps resnet18 FP16); Standard daher 0.
# Erster Lauf: cmake-Konfiguration + Build per 'python -m build'. Wiederaufnahme (build/build.ninja vorhanden): direkt ninja.
# Die riesigen generierten ATen-Dateien (Register*/Operators_*, cc1plus je ca. 3,6 GB) liegen in einem ninja-Pool mit depth 1,
# sonst OOM bzw. haengende VM (6 GB war zu knapp, deshalb pb mit 12 GB / 10 CPUs; MAX_JOBS=5).
if [ -f build/build.ninja ]; then
  (cd build && cmake -DUSE_CUDNN=$USE_CUDNN -DCUDNN_INCLUDE_DIR=/usr/include -DCUDNN_LIBRARY=/usr/lib/aarch64-linux-gnu/libcudnn.so . > /w/torch/reconfigure.log 2>&1)   # USE_CPU_VECTORIZATION=0 wirksam machen
  python3 - <<'P'
import re
f='build/build.ninja'; s=open(f).read()
if 'pool heavy' not in s:
    s='pool heavy\n  depth = 1\n\n'+s
    pat=re.compile(r'(build caffe2/CMakeFiles/torch_cpu\.dir/__/aten/src/ATen/(?:Register|Operators_|CompositeViewCopy|UfuncCPU)[A-Za-z_0-9]*\.cpp\.o:[^\n]*\n(?:  [^\n]*\n)*)')
    s,n=pat.subn(lambda m:m.group(1)+'  pool = heavy\n',s); print('heavy edges',n)
    open(f,'w').write(s)
P
  python3 /w/torch/pool-cuda.py   # schwere CUTLASS/CUDA-Dateien ebenfalls einzeln (GroupMM.cu: OOM bei -j7)
  (cd build && ninja -j${MAX_JOBS} 2>&1 | tee -a /w/torch/build-wheel.log)
fi
pip install -q build scikit-build-core 2>&1 | tail -1
python -m build --wheel --no-isolation 2>&1 | tee /w/torch/build-wheel.log
cp dist/*.whl /w/torch/
# torchvision (passend zu torch 2.14: v0.29.x, vorher Tag prüfen): git clone -b <tag> https://github.com/pytorch/vision; FORCE_CUDA=1 TORCH_CUDA_ARCH_LIST=5.3 python3 setup.py bdist_wheel
