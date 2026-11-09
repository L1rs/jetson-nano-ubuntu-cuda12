#!/bin/bash
# Im Container pb (ubuntu:26.04 arm64): Jetson-CUDA-12.6-Toolkit + Buildtools. Platzsparend: apt löscht Debs nach der Installation.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq; apt-get install -y -qq curl ca-certificates >/dev/null
echo "deb [trusted=yes arch=arm64] https://repo.download.nvidia.com/jetson/common r36.4 main" > /etc/apt/sources.list.d/jetson.list
apt-get update -qq || true
apt-get install -y -o APT::Keep-Downloaded-Packages=false --no-install-recommends cuda-nvcc-12-6 cuda-cudart-dev-12-6 cuda-libraries-dev-12-6 \
  cuda-nvml-dev-12-6 cuda-driver-dev-12-6 cuda-nvtx-12-6 cuda-cupti-dev-12-6 cuda-cuobjdump-12-6 \
  gcc-13 g++-13 git cmake ninja-build make python3 python3-dev python3-venv python3-pip python3-yaml \
  python3-numpy python3-setuptools libopenblas-dev
# Platz: statische CUDA-Libs (außer cudart/culibos), Doku
cd /usr/local/cuda-12.6/targets/aarch64-linux/lib
rm -f libcublas*_static.a libcufft*_static.a libcurand_static.a libcusolver*_static.a libcusparse_static.a libnpp*_static.a libnvJitLink_static.a libnvptxcompiler_static.a libnvrtc*_static.a
rm -rf /usr/local/cuda-12.6/doc /usr/local/cuda-12.6/extras /var/lib/apt/lists/*
# glibc 2.43 vs CUDA-12.6-Header: rsqrt/sinpi/cospi brauchen noexcept(true)
H=/usr/local/cuda-12.6/targets/aarch64-linux/include/crt/math_functions.h
sed -i -E 's/^(extern __DEVICE_FUNCTIONS_DECL__ __device_builtin__ (float|double) +(rsqrt|rsqrtf|sinpi|sinpif|cospi|cospif)\((float|double) x\));/\1 noexcept(true);/' $H
grep -nE "rsqrt|sinpi|cospi" $H | head
