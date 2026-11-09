#!/bin/bash
set -e
export PATH=/usr/local/cuda-12.6/bin:$PATH CUDA_HOME=/usr/local/cuda-12.6
. /work/venv/bin/activate
pip install -q /w/torch/torch-2.14.1*.whl numpy wheel setuptools pillow
cd /work
[ -d vision ] || git clone --depth 1 -b v0.29.2 https://github.com/pytorch/vision
cd vision
export CC=gcc-13 CXX=g++-13 CUDAHOSTCXX=g++-13
export FORCE_CUDA=1 TORCH_CUDA_ARCH_LIST=5.3 MAX_JOBS=${MAX_JOBS:-6}
export TORCHVISION_USE_NVJPEG=0 TORCHVISION_USE_FFMPEG=0 TORCHVISION_USE_VIDEO_CODEC=0
# ponytail: ohne png/jpeg-Decoder-Libs im Bild: setup.py nimmt, was da ist (Bilder laden via PIL)
python setup.py bdist_wheel -d /w/torch
echo VISION_DONE
