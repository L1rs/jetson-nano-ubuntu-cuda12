#!/bin/bash
# Läuft IM Container pb (Ubuntu 26.04 arm64) nach Installation von cuda-toolkit-12-6 + gcc-13 (siehe build-torch.sh, Abschnitt 1).
set -e
export PATH=/usr/local/cuda-12.6/bin:$PATH
mkdir -p /work /w/cuda-samples && cd /work
[ -d cuda-samples ] || git clone --depth 1 -b v12.5 https://github.com/NVIDIA/cuda-samples
S=cuda-samples/Samples/1_Utilities
# ponytail: das Laufzeit-chroot ist 22.04 (glibc 2.35), gebaut wird auf 26.04 (glibc 2.43, GLIBCXX 3.4.32).
# libstdc++ statisch + zwei Ersatzsymbole, damit die Binaries auf beiden laufen; entfaellt mit dem 26.04-Rootfs.
cat > /work/compat235.c <<'EOC'
#include <stdlib.h>
#include <sys/random.h>
unsigned long __isoc23_strtoul(const char *s, char **e, int b) { return strtoul(s, e, b); }
unsigned int arc4random(void) { unsigned int v; while (getrandom(&v, sizeof v, 0) != sizeof v); return v; }
EOC
gcc-13 -std=c11 -O2 -fPIC -c -o /work/compat235.o /work/compat235.c   # -std=c11: kein C23-Redirect auf __isoc23_strtoul
for s in deviceQuery bandwidthTest; do
  # chroot ist 22.04 (GLIBCXX 3.4.30), gcc-13 braucht 3.4.32 -> libstdc++ statisch
  rm -f $S/$s/$s $S/$s/*.o
  make -C $S/$s SMS=53 HOST_COMPILER=g++-13 EXTRA_CCFLAGS="-static-libstdc++ -static-libgcc" EXTRA_LDFLAGS=/work/compat235.o -j2
  cp $S/$s/$s /w/cuda-samples/
done
cat > /w/cuda-samples/hello.cu <<'EOC'
#include <cstdio>
__global__ void add(const int*a,const int*b,int*c,int n){int i=blockIdx.x*blockDim.x+threadIdx.x;if(i<n)c[i]=a[i]+b[i];}
int main(){const int n=1<<20;size_t sz=n*sizeof(int);
 int*a=new int[n],*b=new int[n],*c=new int[n];for(int i=0;i<n;i++){a[i]=i;b[i]=2*i;}
 int*da,*db,*dc;cudaMalloc(&da,sz);cudaMalloc(&db,sz);cudaMalloc(&dc,sz);
 cudaMemcpy(da,a,sz,cudaMemcpyHostToDevice);cudaMemcpy(db,b,sz,cudaMemcpyHostToDevice);
 add<<<(n+255)/256,256>>>(da,db,dc,n);
 cudaError_t e=cudaMemcpy(c,dc,sz,cudaMemcpyDeviceToHost);
 if(e!=cudaSuccess){printf("FAIL %s\n",cudaGetErrorString(e));return 1;}
 for(int i=0;i<n;i++)if(c[i]!=3*i){printf("FAIL at %d\n",i);return 1;}
 printf("hello.cu OK\n");return 0;}
EOC
nvcc -ccbin g++-13 -Xcompiler -static-libstdc++,-static-libgcc -gencode arch=compute_53,code=sm_53 -gencode arch=compute_53,code=compute_53 -o /w/cuda-samples/hello /w/cuda-samples/hello.cu /work/compat235.o
cuobjdump --list-elf /w/cuda-samples/hello
for f in /w/cuda-samples/{deviceQuery,bandwidthTest,hello}; do objdump -T $f | grep -E "GLIBC_2\.(3[6-9]|4)|GLIBCXX_3\.4\.3[1-9]" && { echo "$f braucht zu neue glibc"; exit 1; }; done; echo SAMPLES_OK
