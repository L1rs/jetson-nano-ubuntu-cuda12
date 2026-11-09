#!/bin/sh
# SPDX-License-Identifier: MIT
# Sets up TensorRT 8.0 for Ubuntu 26.04 in $R/opt/nanotrt, using the TensorRT 8.0 / cuDNN 8 / CUDA 10.2 libraries
# of the user's own JetPack 4.6 install (nothing is downloaded or redistributed). Run as root, either under L4T
# (by install.sh, R=/opt/u2604) or inside Ubuntu 26.04 (R=/, L4T mounted at /media/l4t).
# Why this works: the CUDA 12.6 driver (libcuda r36) runs applications built for CUDA 10.2, and cuBLAS 10 /
# cuDNN 8 / TensorRT 8.0 contain sm_53 kernels. Two libraries of the old L4T stack talk to the old kernel ABI
# (libnvmedia, libnvdla_compiler: the DLA accelerator, which the Nano does not have); they are replaced by stubs.
set -e
HERE=$(dirname "$(readlink -f "$0")")
if [ -d /media/l4t/usr/src/tensorrt ]; then S=/media/l4t; R=${R:-/}; else S=; R=${R:-/opt/u2604}; fi
L=/media/l4t                     # where the L4T root is seen from Ubuntu 26.04
T=$R/opt/nanotrt; mkdir -p $T/lib $T/bin
[ -f $S/usr/lib/aarch64-linux-gnu/libnvinfer.so.8 ] || { echo "TensorRT 8 not found in L4T (JetPack 4.6 with TensorRT needed), skipping"; exit 0; }
for f in $S/usr/lib/aarch64-linux-gnu/libnvinfer*.so.8* $S/usr/lib/aarch64-linux-gnu/libnvonnxparser.so.8* \
         $S/usr/lib/aarch64-linux-gnu/libnvparsers.so.8* $S/usr/lib/aarch64-linux-gnu/libcudnn*.so.8* \
         $S/usr/local/cuda-10.2/lib64/lib*.so.10*; do
  ln -sfn $L${f#$S} $T/lib/$(basename $f)
done
ln -sfn $L/usr/src/tensorrt/bin/trtexec $T/bin/trtexec.bin
# compile with the L4T toolchain and headers (g++ 7, TensorRT/CUDA 10.2 headers)
W=$S/tmp/nanotrt-build; rm -rf $W; mkdir -p $W; cp $HERE/*.c $HERE/*.cpp $W/
chroot ${S:-/} sh -c "cd /tmp/nanotrt-build &&
  gcc -O2 -shared -fPIC -o libnvmedia.so nvmedia-stub.c &&
  gcc -O2 -shared -fPIC -o libnvdla_compiler.so nvdla-stub.c &&
  g++ -O2 -shared -fPIC -o libtrt_shim.so trt_shim.cpp -I/usr/local/cuda-10.2/include -lnvinfer \
      -Wl,--disable-new-dtags,-rpath,/opt/nanotrt/lib"
cp $W/libnvmedia.so $W/libnvdla_compiler.so $W/libtrt_shim.so $T/lib/; rm -rf $W
install -m 755 $HERE/nano-trt $R/usr/local/bin/nano-trt
install -m 644 $HERE/nanotrt.py $T/nanotrt.py
echo "TensorRT 8.0 set up in $T"
