#!/bin/bash
# SPDX-License-Identifier: MIT
# Run as root on the Jetson Nano (L4T 32.7 / JetPack 4.6, internet access); normally called by ../install.sh.
# Builds Ubuntu 26.04 in /opt/u2604, the initramfs /boot/mainline/initrd-u2604.img and the extlinux entry "u2604".
# Requires: mainline kernel in /boot/mainline, /lib/modules/$KVER (6.18.62), L4T firmware in /lib/firmware.
# Options (env): CPU_KHZ (default 918000 = nano-power safe; max = highest clock the kernel offers (1555500), needs a strong 5 V supply), JETSON_USER/JETSON_PASS (jetson/jetson).
set -e
HERE=$(dirname "$(readlink -f "$0")")
R=/opt/u2604; V=36.4.7-20250918154033; D=/opt/jp6/debs
P=https://repo.download.nvidia.com/jetson/t234/pool/main/n
PARTUUID=$(blkid -s PARTUUID -o value "$(findmnt -no SOURCE /)")
KVER=${KVER:-6.18.62}; U=${JETSON_USER:-jetson}; PW=${JETSON_PASS:-jetson}; CPU_KHZ=${CPU_KHZ:-918000}
log() { echo "=== $(date +%T) $*"; }
chr() { chroot $R /usr/bin/env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 "$@"; }
mnt() { for m in proc sys dev dev/pts; do mountpoint -q $R/$m || mount --bind /$m $R/$m; done; }
umnt() { umount -l $R/dev/pts $R/dev $R/sys $R/proc 2>/dev/null || true; }
trap umnt EXIT

log "1. ubuntu-base"
mkdir -p $R
if [ ! -x $R/bin/sh ]; then
  curl -fL -o /opt/u2604-base.tgz https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04.1-base-arm64.tar.gz
  tar -xzf /opt/u2604-base.tgz -C $R; rm /opt/u2604-base.tgz
fi
mnt
rm -f $R/etc/resolv.conf; echo "nameserver 1.1.1.1" > $R/etc/resolv.conf   # ponytail: fest, spaeter systemd-resolved-Stub
printf '#!/bin/sh\nexit 101\n' > $R/usr/sbin/policy-rc.d; chmod +x $R/usr/sbin/policy-rc.d  # keine Dienste im chroot starten

log "2. Pakete"
echo 'Acquire::Retries "5";' > $R/etc/apt/apt.conf.d/80-retries
chr dpkg --configure -a || true   # after a freeze/abort during an earlier run
chr apt-get update -qq
chr apt-get install -y --no-install-recommends $(grep -v "^#" $HERE/packages.txt) >/dev/null

log "3. System"
echo jetson > $R/etc/hostname; printf '127.0.0.1 localhost\n127.0.1.1 jetson\n' > $R/etc/hosts
TZ_=$(cat /etc/timezone 2>/dev/null || echo Etc/UTC); ln -sf /usr/share/zoneinfo/$TZ_ $R/etc/localtime; echo $TZ_ > $R/etc/timezone
chr userdel -r ubuntu 2>/dev/null || true
chr groupadd -f i2c
chroot $R id $U >/dev/null 2>&1 || chr useradd -m -s /bin/bash -G sudo,video,render,i2c,input $U
echo $U:$PW | chroot $R chpasswd
chr systemctl enable ssh NetworkManager systemd-resolved systemd-timesyncd avahi-daemon >/dev/null 2>&1 || true
ln -sf /run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf
# Host-Keys vom L4T-System uebernehmen (gleicher SSH-Fingerprint wie bisher)
cp -a /etc/ssh/ssh_host_* $R/etc/ssh/
# Netzwerk: WLAN-Profile direkt auf dem Geraet kopieren (Inhalt wird nie gelesen), eth0 per DHCP
S=$R/etc/NetworkManager/system-connections; mkdir -p $S
mkdir -p $R/etc/NetworkManager/conf.d; touch $R/etc/NetworkManager/conf.d/10-globally-managed-devices.conf   # Ubuntu leaves ethernet unmanaged without netplan
cp -a /etc/NetworkManager/system-connections/*.nmconnection $S/ 2>/dev/null || echo "WARN: keine WLAN-Profile"
cat > $S/eth0.nmconnection <<X
[connection]
id=eth0
uuid=$(cat /proc/sys/kernel/random/uuid)
type=ethernet
interface-name=eth0
[ipv4]
method=auto
[ipv6]
method=auto
X
chown root:root $S/*; chmod 600 $S/*
# /media/l4t = p1 mit dem alten System (wird vom Initramfs gebunden)
mkdir -p $R/media/l4t

log "4. Kernel-Module und Firmware"
rm -rf $R/usr/lib/modules/6.18.*; mkdir -p $R/usr/lib/modules $R/usr/lib/firmware
cp -a /lib/modules/$KVER $R/usr/lib/modules/
cp -a /lib/firmware/. $R/usr/lib/firmware/
chr depmod $KVER
echo nvgpu > $R/etc/modules-load.d/nvgpu.conf; echo i2c-dev > $R/etc/modules-load.d/i2c-dev.conf
# kein blacklist: systemd-modules-load wuerde es ablehnen; ein paralleler Alias-Autoload ist harmlos

log "5. JetPack-6-Userspace (L4T r36.4)"
mkdir -p $D
for p in core cuda 3d-core; do
  [ -d $D/x-$p ] && continue
  f=$D/nvidia-l4t-${p}_${V}_arm64.deb
  [ -f $f ] || curl -fL -o $f $P/nvidia-l4t-$p/nvidia-l4t-${p}_${V}_arm64.deb
  mkdir $D/x-$p; dpkg-deb -x $f $D/x-$p
done
N=$R/usr/lib/aarch64-linux-gnu/nvidia; mkdir -p $N
cp -a $D/x-core/usr/lib/aarch64-linux-gnu/nvidia/. $N/
cp -a $D/x-cuda/usr/lib/aarch64-linux-gnu/nvidia/. $N/
cp -a $D/x-3d-core/usr/lib/aarch64-linux-gnu/nvidia/libnvidia-ptxjitcompiler.so* $N/
cp -a $D/x-core/etc/nv_tegra_release $R/etc/
echo /usr/lib/aarch64-linux-gnu/nvidia > $R/etc/ld.so.conf.d/nvidia-tegra.conf
echo /usr/local/cuda-12.6/targets/aarch64-linux/lib > $R/etc/ld.so.conf.d/cuda-12-6.conf
# CUDA-Laufzeit (cudart, cublas) aus dem Jetson-Repo; nur wenn apt dafuer keine nvidia-l4t-* (Kernel!) braeuchte
echo "deb [trusted=yes arch=arm64] https://repo.download.nvidia.com/jetson/common r36.4 main" > $R/etc/apt/sources.list.d/jetson.list
chr apt-get update -qq || true
CP=$(grep -v "^#" $HERE/cuda-packages.txt | tr "\n" " ")   # was PyTorch braucht
if chr apt-get install -s --no-install-recommends $CP > /tmp/u2604-cuda-sim.log 2>&1 && ! grep -q nvidia-l4t /tmp/u2604-cuda-sim.log; then
  chr apt-get install -y --no-install-recommends $CP >/dev/null || { echo "ERROR: CUDA 12.6 runtime install failed"; exit 1; }
else echo "ERROR: CUDA 12.6 runtime not installable (see $R/tmp/u2604-cuda-sim.log)"; exit 1; fi
rm -f $R/etc/apt/sources.list.d/jetson.list   # ponytail: damit apt upgrade nie L4T-Pakete zieht
chr ldconfig

log "6. Fixups: tegra_fuse-Parameter, udev"
F=$R/var/lib/tegra-fake/tegra_fuse/parameters; mkdir -p $F
echo 33 > $F/tegra_chip_id; echo 2 > $F/tegra_chip_rev; echo 0 > $F/tegra_platform; echo 1 > $F/tegra_prod_mode
cat > $R/etc/systemd/system/tegra-fake-fuse.service <<'X'
[Unit]
Description=Fake tegra_fuse sysfs parameters for libnvrm (Mainline hat sie nicht)
After=systemd-modules-load.service
Before=multi-user.target
[Service]
Type=oneshot
RemainAfterExit=yes
# ponytail: Overlay ueber /sys/module (ro); spaeter geladene Module erscheinen darin evtl. nicht
ExecStart=/bin/mount -t overlay -o ro,lowerdir=/var/lib/tegra-fake:/sys/module overlay /sys/module
[Install]
WantedBy=multi-user.target
X
chr systemctl enable tegra-fake-fuse >/dev/null 2>&1
cat > $R/etc/systemd/system/tegra-clocks.service <<X
[Unit]
Description=EMC-Takt festlegen (tegra210-emc, Tabelle nvidia,emc-table) und CPU-Takt deckeln
After=sys-kernel-debug.mount
[Service]
Type=oneshot
RemainAfterExit=yes
# Kalibrierknoepfe: EMC_HZ (Tabelle hat nur 204000000 und 1600000000), CPU_KHZ, CPUS (online).
# Mainline bietet auf dem Nano bis 1555500 kHz an (cpuinfo_max_freq). Mit dem schwachen Netzteil haengt der Nano bei
# EMC 1600 + 4 Kernen 1428 MHz unter Last (wie MAXN unter L4T); 4x 918 MHz hielt 5 min Volllast.
# ponytail: fester EMC-Takt statt actmon/devfreq, Skalierung erst mit Interconnect-Anbindung
Environment=EMC_HZ=1600000000 CPU_KHZ=918000 CPUS=4
# CPU_KHZ from nano-power (safe 918000 / max = cpuinfo_max_freq, 1555500)
EnvironmentFile=-/etc/default/nano-power
ExecStart=/bin/sh -c 'for c in 1 2 3; do echo \$((c < CPUS)) > /sys/devices/system/cpu/cpu\$c/online; done; for f in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_max_freq; do echo \$CPU_KHZ > \$f; done; echo \$EMC_HZ > /sys/kernel/debug/emc/min_rate'
[Install]
WantedBy=multi-user.target
X
chr systemctl enable tegra-clocks >/dev/null 2>&1
echo CPU_KHZ=$CPU_KHZ > $R/etc/default/nano-power
install -m 755 $HERE/nano-power $R/usr/local/sbin/nano-power
cat > $R/etc/udev/rules.d/60-tegra-gpu.rules <<'X'
SUBSYSTEM=="nvidia-gpu*", GROUP="video", MODE="0660"
SUBSYSTEM=="host1x-fence", GROUP="video", MODE="0660"
KERNEL=="nvmap", GROUP="video", MODE="0660"
KERNEL=="renderD*", GROUP="render", MODE="0660"
X

log "7. Aufraeumen"
chr apt-get clean; rm -f $R/usr/sbin/policy-rc.d; rm -rf $R/var/lib/apt/lists/*
umnt

log "8. Initramfs"
I=/opt/u2604-initramfs; rm -rf $I; mkdir -p $I/bin $I/proc $I/sys $I/dev $I/mnt $I/new
cp $R/usr/bin/busybox $I/bin/busybox; cp $HERE/init $I/init
chmod +x $I/init; mknod $I/dev/console c 5 1; mknod $I/dev/null c 1 3
mkdir -p $I/lib/firmware/nvidia/tegra210; cp /lib/firmware/nvidia/tegra210/xusb.bin $I/lib/firmware/nvidia/tegra210/  # tegra-xusb (built-in) laedt sie vor dem Root-Wechsel
(cd $I && find . | cpio -o -H newc 2>/dev/null | gzip -9) > /boot/mainline/initrd-u2604.img
rm -rf $I

log "9. extlinux"
E=/boot/extlinux/extlinux.conf
[ -f $E.bak-u2604 ] || cp $E $E.bak-u2604
grep -q "^LABEL u2604" $E || cat >> $E <<X

LABEL u2604
      MENU LABEL Ubuntu 26.04 mainline
      LINUX /boot/mainline/Image
      INITRD /boot/mainline/initrd-u2604.img
      FDT /boot/mainline/tegra210-p3450-0000.dtb
      APPEND console=ttyS0,115200n8 earlycon root=PARTUUID=$PARTUUID rw rootwait rootfstype=ext4 net.ifnames=0
X
du -sh $R /boot/mainline/initrd-u2604.img; grep -n "^LABEL\|^DEFAULT" $E
log "U2604_DONE"
