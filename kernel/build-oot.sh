#!/bin/bash
# Im Container "kb": container exec kb bash /tools/build-oot.sh
# Mounts: /w=analyse/build, /tools, /src=analyse/src. Kernel (fertig gebaut): /build/linux-$V
set -e
K=/build/linux-${V:-6.18.62}
S=/build/kernel-oot            # case-sensitive Kopie, /src ist case-insensitive
OOT=$S/nvidia-oot
CT=$S/out/nvidia-conftest
apt-get update -qq && apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev kmod rsync >/dev/null
[ -f $K/Module.symvers ] || { echo "Kernel nicht fertig gebaut"; exit 1; }

printf '#!/bin/sh\nexec gcc -std=gnu17 "$@"\n' > /usr/local/bin/gcc17; chmod +x /usr/local/bin/gcc17
# SKIP_SYNC=1 behaelt die Arbeitskopie (zum Iterieren an den Quellen)
if [ -z "$SKIP_SYNC" ]; then
  mkdir -p $S && rsync -a --delete --exclude .git --exclude out /src/kernel-oot/ $S/
  # Patch liegt in analyse/patches/, vorher nach analyse/build/ kopieren (/w ist der einzige beschreibbare Mount)
  patch -p1 -d $S < /w/oot-6.18-t210.patch
fi

# conftest (einmalig, erzeugt $CT/nvidia/conftest/*.h)
mkdir -p $CT/nvidia && cp -a $OOT/scripts/conftest/* $CT/nvidia/
make ARCH=arm64 src=$CT/nvidia obj=$CT/nvidia CC=/usr/local/bin/gcc17 LD=ld \
  NV_KERNEL_SOURCES=$K NV_KERNEL_OUTPUT=$K -f $CT/nvidia/Makefile

# host1x kommt aus dem Kernel (in-tree TEGRA_HOST1X), deshalb ohne $OOT/drivers/gpu/host1x/include
INC="-I$CT -I$OOT/include -I$OOT/drivers/video/tegra/host -Wno-error"
SYMS=""
mk() {  # $1 = Verzeichnis relativ zu $S, dessen Module.symvers danach an SYMS haengt
  make -C $K ARCH=arm64 M=$S/$1 CC=/usr/local/bin/gcc17 \
    CONFIG_TEGRA_OOT_MODULE=m KCFLAGS="$INC" \
    srctree.nvidia-oot=$OOT srctree.nvidia=$OOT srctree.nvconftest=$CT \
    KBUILD_EXTRA_SYMBOLS="$SYMS" modules
  SYMS="$SYMS $S/$1/Module.symvers"
}
mk nvidia-oot/drivers/platform/tegra/mc-utils
# OOT host1x und host1x-nvhost entfallen: nvgpu nutzt den in-tree host1x direkt (os/linux/nvhost_host1x.c).
# ponytail: host1x-nvhost (nvhost_* fuer nvdla/pva/vic auf T194+) nicht gebaut, bei Bedarf gegen in-tree host1x portieren.
mk nvidia-oot/drivers/gpu/host1x-fence
mk nvidia-oot/drivers/video/tegra/nvmap
mk nvgpu/drivers/gpu/nvgpu

rm -rf /w/out/oot && mkdir -p /w/out/oot
for m in platform/tegra/mc-utils/mc-utils gpu/host1x-fence/host1x-fence video/tegra/nvmap/nvmap; do cp -v $OOT/drivers/$m.ko /w/out/oot/; done
cp -v $S/nvgpu/drivers/gpu/nvgpu/nvgpu.ko /w/out/oot/
echo OOT_DONE
