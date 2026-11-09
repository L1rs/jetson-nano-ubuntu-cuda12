#!/bin/bash
# Laeuft im Container (ubuntu, arm64). /w = analyse/build auf dem Mac.
set -e
V=${V:-6.18.62}   # longterm 6.18.y (kernel.org)
mkdir -p /build && cd /build
apt-get update -qq && apt-get install -y -qq build-essential bc bison flex libssl-dev libelf-dev cpio kmod xz-utils curl python3 >/dev/null
[ -d linux-$V ] || (curl -sL https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-$V.tar.xz | tar xJ)
cd linux-$V
# Tested configuration (kernel/config-6.18-t210); the defconfig path below is only the fallback it was made from
[ -f .config ] || cp /tools/config-6.18-t210 .config 2>/dev/null || true
if [ ! -f .config ]; then
  make -s defconfig
  # nur Tegra behalten, spart Zeit und Platz
  for p in $(grep -oE '^CONFIG_ARCH_[A-Z0-9_]+=y' .config | cut -d= -f1 | sed 's/CONFIG_//' | grep -vE '^ARCH_(TEGRA|TEGRA_210_SOC)$'); do scripts/config -d $p; done
  scripts/config -e ARCH_TEGRA -e ARCH_TEGRA_210_SOC -d DRM_NOUVEAU -m DRM_TEGRA -e IKCONFIG -e IKCONFIG_PROC
  make -s olddefconfig
fi
# in-tree host1x + tegra-drm (libnvrm_host1x aus JP6 braucht /dev/dri/renderD* mit Treiber "tegra"
# und die host1x-UAPI SYNCPOINT_WAIT usw., die nur mit DRM_TEGRA_STAGING im ioctl-Table steht),
# Kamera-Treiber fuer spaeter; OOT host1x wird nicht mehr gebaut
# EMC-Skalierung: Treiber fest eingebaut, Tabelle als DT-Property (patches/emc-t210-dt-table.patch,
# Kopie in build/, Daten aus tools/emc-table.py, eingetragen von deploy-mainline.sh)
grep -q 'nvidia,emc-table' drivers/memory/tegra/tegra210-emc-core.c || patch -p1 < /w/emc-t210-dt-table.patch
scripts/config -e TEGRA210_EMC
# Kamera: IMX219 an CAM0 (tools/nano-imx219.dtsi, Werte aus L4T-DTB) an den p3450-DTS haengen
cp /tools/nano-imx219.dtsi arch/arm64/boot/dts/nvidia/
grep -q nano-imx219 arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts || echo '#include "nano-imx219.dtsi"' >> arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dts
scripts/config -m TEGRA_HOST1X -m DRM_TEGRA -e DRM_TEGRA_STAGING -e STAGING -e STAGING_MEDIA -m VIDEO_TEGRA -m VIDEO_IMX219
make -s olddefconfig
grep -E "^CONFIG_(VIDEO_TEGRA|VIDEO_IMX219|DRM_TEGRA|IWLWIFI|IWLMVM|PCI_TEGRA|MMC_SDHCI_TEGRA|EXT4_FS|R8169|SERIAL_8250_TEGRA|TEGRA_HOST1X|TEGRA_IOMMU_SMMU|TEGRA210_EMC)=" .config
make -j$(nproc) Image modules dtbs 2>&1 | grep -E "error|Error|warning: .*undefined" || true
rm -rf /w/out && mkdir -p /w/out
cp arch/arm64/boot/Image /w/out/Image-$V
cp arch/arm64/boot/dts/nvidia/tegra210-p3450-0000.dtb /w/out/
rm -rf /build/mod; make -s modules_install INSTALL_MOD_PATH=/build/mod INSTALL_MOD_STRIP=1
cd /w/out && tar czf modules-$V.tgz -C /build/mod lib && ls -la
echo BUILD_DONE
