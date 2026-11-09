#!/bin/bash
# SPDX-License-Identifier: MIT
# install.sh: Ubuntu 26.04 + Linux 6.18.62 + CUDA 12.6 + PyTorch 2.14 + TensorRT 8 on the Jetson Nano 4 GB (T210).
# EXPERIMENTAL: every step was done and verified by hand on one board, this script automates them. Use a spare SD card.
#
#   sudo ./install.sh          shows what it will do, asks a few questions, then installs (about 1 hour)
#   sudo ./install.sh --plan   only shows what it would do (changes nothing)
#   sudo ./install.sh -y       no questions, use the defaults / environment variables below
#
# WHAT IT CHANGES. Start from an L4T 32.6/32.7 system (JetPack 4.6.x: NVIDIA's SD card image with Ubuntu 18.04, or an
# Ubuntu 20.04 image based on it); see docs/install.md. L4T stays on the card and stays bootable.
#   /boot/mainline/              new: kernel 6.18.62, device tree, initramfs
#   /lib/modules/6.18.62/        new: kernel modules (incl. the patched NVIDIA GPU driver nvgpu)
#   /boot/extlinux/extlinux.conf new boot entry "u2604" (+ DEFAULT u2604 if chosen); backup: extlinux.conf.bak-jn
#   /opt/u2604/                  new: the complete Ubuntu 26.04 system (about 8 GB)
#   /opt/jn-install/             downloads (may be deleted afterwards)
#   L4T packages nvidia-l4t-*    put on "apt hold" (only with the update lock)
#   L4T power mode               5 W while installing (MAXN can freeze the Nano on weak supplies), restored at the end
#   /var/log/jetson-nano-install.log   the complete log of the installation
#   Nothing else in L4T is changed: no partitions, no bootloader, no flash.
#
# WHERE THE FILES COME FROM
#   GitHub release of this project   kernel package, PyTorch/torchvision wheels (verified against SHA256SUMS)
#   cdimage/ports.ubuntu.com         Ubuntu 26.04 base system and packages
#   repo.download.nvidia.com         JetPack 6 (L4T r36.4) userspace with the CUDA 12.6 driver
#   pypi.org                         JupyterLab, numpy, OpenCV, onnx and other Python packages
#   your own L4T system              RAM timing table (from the running device tree), firmware, camera colour file,
#                                    TensorRT 8 / cuDNN 8 / CUDA 10.2 (linked at run time, not copied)
#
# SETTINGS (asked at the start; or set them as environment variables, e.g. sudo UPDATE_LOCK=0 ./install.sh -y)
#   UPDATE_LOCK=1   apt/pip lock against updates that would break the system      (0 = no lock)
#   POWER=safe      CPU 918 MHz, safe on micro-USB supplies; later: sudo nano-power test   (max = full clock now)
#   ROBOT=none      jetbot = start OLED and gamepad services for the Waveshare JetBot board
#   SET_DEFAULT=1   boot Ubuntu 26.04 by default                                   (0 = keep L4T as default)
#   JETSON_USER=jetson JETSON_PASS=jetson   user in the new system (asked interactively; change the password!)
#   SLUG            GitHub owner/repo for downloads and the update check (nano-update)
#   RELEASE_URL     where the release files are downloaded from
set -Eeuo pipefail
REPO=$(dirname "$(readlink -f "$0")")
TAG=v$(cat $REPO/VERSION)
SLUG=${SLUG:-L1rs/jetson-nano-ubuntu-cuda12}     # GitHub owner/repo, also used by nano-update
RELEASE_URL=${RELEASE_URL:-https://github.com/$SLUG/releases/download/$TAG}
export KVER=6.18.62
KERNEL_TGZ=linux-$KVER-t210-jetson-nano.tar.gz
TORCH_WHL=torch-2.14.1a0+git5c48869-cp314-cp314-linux_aarch64.whl
VISION_WHL=torchvision-0.29.2+f122815-py3-none-linux_aarch64.whl
UPDATE_LOCK=${UPDATE_LOCK:-1}; POWER=${POWER:-safe}; ROBOT=${ROBOT:-none}; SET_DEFAULT=${SET_DEFAULT:-1}
export JETSON_USER=${JETSON_USER:-jetson} JETSON_PASS=${JETSON_PASS:-jetson}
W=/opt/jn-install; R=/opt/u2604; E=/boot/extlinux/extlinux.conf; DTB=/boot/mainline/tegra210-p3450-0000.dtb
B=$(tput bold 2>/dev/null || true); N=$(tput sgr0 2>/dev/null || true)
STEP=0; step() { sync; STEP=$((STEP + 1)); echo; echo "${B}=== Step $STEP/10 ($(date +%T)): $*${N}"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------- overview and settings
overview() { cat <<X

${B}Jetson Nano: Ubuntu 26.04 + Linux $KVER + CUDA 12.6 + PyTorch 2.14 + TensorRT 8${N}

This installs a second, modern system next to your L4T. L4T stays on the card and stays bootable.

${B}What will be changed${N} (only on this SD card, only these places):
  /boot/mainline/              new kernel $KVER, device tree, initramfs
  /lib/modules/$KVER/        kernel modules incl. the patched NVIDIA GPU driver
  /boot/extlinux/extlinux.conf new boot entry "u2604" (backup: extlinux.conf.bak-jn)
  /opt/u2604/                  the complete Ubuntu 26.04 system (about 8 GB)
  /opt/jn-install/             downloads (can be deleted afterwards)
  No partitions, no bootloader, no flash memory are touched.

${B}Where the files come from${N}
  GitHub release (this project)   kernel, PyTorch and torchvision for this GPU (checksums verified)
  Ubuntu (cdimage/ports)          Ubuntu 26.04 base system and packages
  NVIDIA (repo.download.nvidia)   JetPack 6 userspace with the CUDA 12.6 driver
  pypi.org                        JupyterLab, numpy, OpenCV, onnx
  your L4T system                 RAM timing table, firmware, camera colour file, TensorRT 8 libraries

${B}Steps${N}: checks, tools, downloads, kernel, device tree, Ubuntu system (20-40 min),
       Python + apps, services (incl. daily update check), update lock, boot entry. About 1 hour, needs internet and 16 GB free.
X
}
ask() {  # ask VAR "question" "explanation" ; y/n question, default = current value of VAR (1 = yes)
  local d=${!1} a; [ "$d" = 1 ] && d=Y/n || d=y/N
  echo; echo "${B}$2${N}"; echo "$3" | sed 's/^/  /'
  read -r -p "  [$d] " a || true
  case "$a" in [yY]*) printf -v "$1" 1 ;; [nN]*) printf -v "$1" 0 ;; esac
}
settings() { cat <<X

${B}Settings${N}
  Update lock      $([ "$UPDATE_LOCK" = 1 ] && echo "on  (apt/pip cannot break kernel, GPU driver, PyTorch)" || echo "OFF (you must avoid kernel/NVIDIA/CUDA/torch updates yourself)")
  CPU clock        $([ "$POWER" = safe ] && echo "safe 918 MHz (works on micro-USB; full clock later: sudo nano-power test)" || echo "max (full clock from the first boot; needs a strong 5 V supply)")
  JetBot services  $([ "$ROBOT" = jetbot ] && echo "on  (OLED status display, gamepad driving)" || echo "off")
  Boot default     $([ "$SET_DEFAULT" = 1 ] && echo "Ubuntu 26.04" || echo "L4T (Ubuntu 26.04 via the boot menu on the serial console)")
  User             $JETSON_USER / $([ "$JETSON_PASS" = jetson ] && echo "password 'jetson' (change it after the first login!)" || echo "your password")
X
}
[ "${1:-}" = --plan ] && { overview; settings; exit 0; }
[ "$(id -u)" = 0 ] || die "run with sudo"
tr -d '\0' < /proc/device-tree/model | grep -q "Jetson Nano" || die "not a Jetson Nano"
rev=$(sed -n 's/^# R32 (release), REVISION: \([0-9]*\).*/\1/p' /etc/nv_tegra_release 2>/dev/null)
[ "${rev:-0}" -ge 6 ] || die "needs L4T 32.6 or newer (JetPack 4.6.x, Ubuntu 18.04 or 20.04 based), see docs/install.md"
[ "$(df --output=avail -BG / | tail -1 | tr -dc 0-9)" -ge 16 ] || die "need at least 16 GB free on /"
[ "$(date +%Y)" -ge 2025 ] || die "the system clock is wrong ($(date)). Connect to the internet, wait a minute, try again"
url_ok() { python3 -c "import sys, urllib.request; urllib.request.urlopen(sys.argv[1], timeout=20)" "$1" 2>/dev/null; }
url_ok https://ports.ubuntu.com/ || die "no internet connection (https://ports.ubuntu.com not reachable)"
url_ok "$RELEASE_URL/SHA256SUMS" || die "release files not reachable: $RELEASE_URL (wrong SLUG or RELEASE_URL?)"
[ -f $E ] || die "$E not found"
overview
if [ "${1:-}" != -y ] && [ -t 0 ]; then
  ask UPDATE_LOCK "Install the update lock? (recommended)" \
"Blocks the few packages that would break this system on 'apt upgrade' or 'pip install':
Ubuntu kernels and bootloaders, NVIDIA desktop drivers, Ubuntu's CUDA 13, PyTorch from PyPI (no driver
for this GPU), and holds the L4T boot packages in the old system. Normal updates keep working."
  p=0; [ "$POWER" = safe ] && p=1
  ask p "Start with the safe CPU clock? (recommended)" \
"Yes: CPU limited to 918 MHz. Micro-USB supplies sag under CPU + GPU load and the Nano then freezes.
Later, with a strong supply (barrel jack 5 V/4 A, battery board):  sudo nano-power test
runs 5 minutes of full load and switches to full clock only if the Nano stays stable.
No: full CPU clock right away (only with a strong supply)."
  [ "$p" = 1 ] && POWER=safe || POWER=max
  j=0; [ "$ROBOT" = jetbot ] && j=1
  ask j "Waveshare JetBot board connected?" \
"Yes: starts the OLED status display and gamepad driving as services (motors move with the gamepad!).
No: robot software is installed anyway, but nothing starts on its own."
  [ "$j" = 1 ] && ROBOT=jetbot || ROBOT=none
  ask SET_DEFAULT "Boot Ubuntu 26.04 by default?" \
"Yes: the Nano starts Ubuntu 26.04. L4T stays in the boot menu (serial console) and on the card.
No: L4T stays the default."
  echo; read -r -s -p "${B}Password for user '$JETSON_USER'${N} (also JupyterLab; Enter = 'jetson'): " pw || true; echo
  [ -n "${pw:-}" ] && JETSON_PASS=$pw
  settings
  read -r -p "Start the installation? [Y/n] " a || true
  case "${a:-y}" in [nN]*) echo "Nothing was changed."; exit 0 ;; esac
else
  settings
fi
# from here on: full log in $LOG, keeps running if the SSH connection drops, power mode 5 W while installing
LOG=/var/log/jetson-nano-install.log; trap '' HUP; exec > >(tee -a --output-error=warn $LOG) 2>&1
trap 'echo; echo "${B}ERROR in step $STEP (install.sh line $LINENO).${N} Log: $LOG"; echo "Fix the cause and run the installer again: finished parts are skipped or redone."' ERR
PM=$(nvpmodel -q 2>/dev/null | grep -x '[0-9]' | tail -1 || true); nvpmodel -m 1 </dev/null >/dev/null 2>&1 || true
export CPU_KHZ=918000; [ "$POWER" = max ] && CPU_KHZ=1912500   # the kernel caps this at the highest supported clock

# ---------------------------------------------------------------- installation
step "Checks passed: Jetson Nano, L4T 32.x, 16 GB free"
mkdir -p $W

step "Tools in L4T: device-tree-compiler, curl, python3"
for i in $(seq 60); do fuser /var/lib/dpkg/lock* >/dev/null 2>&1 || break; echo "waiting for another apt to finish"; sleep 10; done
apt-get update -qq || echo "NOTE: apt-get update reported errors, trying anyway"
apt-get install -y -qq device-tree-compiler curl python3 cpio >/dev/null

step "Download release files from $RELEASE_URL"
for f in SHA256SUMS $KERNEL_TGZ $TORCH_WHL $VISION_WHL; do
  if [ ! -f $W/$f ]; then curl -fL --retry 3 -o $W/$f.part "$RELEASE_URL/$f"; mv $W/$f.part $W/$f; fi
done
(cd $W && sha256sum -c --ignore-missing SHA256SUMS) || die "checksum mismatch"

step "Kernel $KVER and modules -> /boot/mainline, /lib/modules/$KVER"
[ -f $E.bak-jn ] || cp $E $E.bak-jn
tar xzf $W/$KERNEL_TGZ -C /
depmod $KVER

step "Device tree: GPU on, RAM timing table of this board, I2C on header pins 3/5"
dtc -q -I fs -O dts /proc/device-tree > $W/l4t-live.dts 2>/dev/null
ok=; for rc in 0x00 0x01 0x02 0x03; do   # the bootloader trains only the table matching this board's RAM code
  python3 $REPO/kernel/emc-table.py $W/l4t-live.dts $rc $W/emc.bin >/dev/null 2>&1 && ok=$rc && break
done
[ -n "$ok" ] || die "no trained EMC table found in the live device tree"
echo "RAM code $ok"
fdtput -t s $DTB /gpu@57000000 compatible nvidia,tegra210-gm20b
fdtput -d $DTB /gpu@57000000 iommus 2>/dev/null || true
fdtput -t bx $DTB /external-memory-controller@7001b000 nvidia,emc-table $(od -An -v -tx1 $W/emc.bin)
fdtput -t s $DTB /i2c@7000c400 status okay

step "Ubuntu 26.04 system in $R (downloads about 1 GB, 20-40 min; see rootfs/build-rootfs.sh)"
bash $REPO/rootfs/build-rootfs.sh

step "Python environment ~/torch-venv: PyTorch, JupyterLab, camera, robot software, TensorRT"
chr() { chroot $R /usr/bin/env DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 HOME=/root "$@"; }
for m in proc sys dev dev/pts; do mountpoint -q $R/$m || mount --bind /$m $R/$m; done
trap 'umount -l $R/dev/pts $R/dev $R/sys $R/proc 2>/dev/null || true' EXIT
mv $R/etc/resolv.conf $R/etc/resolv.conf.jn; cp -L /etc/resolv.conf $R/etc/resolv.conf   # chroot needs DNS
H=/home/$JETSON_USER; V=$H/torch-venv
cp $W/$TORCH_WHL $W/$VISION_WHL $REPO/rootfs/venv-requirements.txt $R/tmp/
rm -rf $R$V   # a rerun after a crash must not keep half-written files (pip would skip them)
chr su - $JETSON_USER -c "python3 -m venv --system-site-packages $V && $V/bin/pip install -q /tmp/$TORCH_WHL /tmp/$VISION_WHL -r /tmp/venv-requirements.txt"
rm -f $R/tmp/*.whl $R/tmp/venv-requirements.txt
SP=$(chr $V/bin/python -c 'import site; print(site.getsitepackages()[0])')
# camera (IMX219 raw Bayer -> RGB on the CPU); colour/shading data from L4T if present
mkdir -p $R/opt/nanocam; install -m 755 $REPO/camera/nanocam.py $R/opt/nanocam/
cp /var/nvidia/nvcam/settings/camera_overrides.isp $R/opt/nanocam/ 2>/dev/null || echo "NOTE: no camera_overrides.isp in L4T, colours uncorrected (see docs/camera.md)"
echo /opt/nanocam > $R$SP/nanocam.pth; ln -sf /opt/nanocam/nanocam.py $R/usr/local/bin/nanocam
# robot software (JetBot, JetRacer)
mkdir -p $R$H/jetbot $R$H/jetracer/jetracer
cp -r $REPO/jetbot/. $R$H/jetbot/
cp $REPO/jetracer/nvidia_racecar.py $REPO/jetracer/racecar.py $REPO/jetracer/camera.py $R$H/jetracer/jetracer/; touch $R$H/jetracer/jetracer/__init__.py
cp $REPO/jetracer/road_following.py $R$H/jetracer/
echo $H/jetbot > $R$SP/jetbot-local.pth; echo $H/jetracer > $R$SP/jetracer-local.pth
# TensorRT 8 from this L4T install (JetPack 4.6), used from Python via nanotrt (docs/tensorrt.md)
R=$R sh $REPO/tensorrt/build.sh || echo "NOTE: TensorRT setup failed, models run in PyTorch (see docs/tensorrt.md)"
echo /opt/nanotrt > $R$SP/nanotrt.pth
# JupyterLab on :8888, password = user password
mkdir -p $R$H/.jupyter
HASH=$(chr $V/bin/python -c "import sys; from jupyter_server.auth import passwd; print(passwd(sys.argv[1]))" "$JETSON_PASS")
cat > $R$H/.jupyter/jupyter_server_config.py <<X
c.ServerApp.ip = "0.0.0.0"
c.ServerApp.port = 8888
c.ServerApp.open_browser = False
c.ServerApp.root_dir = "$H"
c.PasswordIdentityProvider.hashed_password = "$HASH"
X
chr chown -R $JETSON_USER:$JETSON_USER $H
chr $V/bin/python -c "import torch, torchvision, numpy, cv2, onnx, jupyterlab; print('Python environment ok: torch', torch.__version__)" \
  || die "Python environment incomplete (import failed, see above)"

step "Services: JupyterLab, clock scaling$([ "$ROBOT" = jetbot ] && echo ", JetBot OLED + gamepad"), swap, login message"
svc() {  # name description user exec
  cat > $R/etc/systemd/system/$1.service <<X
[Unit]
Description=$2
After=network-online.target
[Service]
User=$3
WorkingDirectory=$H
ExecStart=$4
KillSignal=SIGINT
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
X
  chr systemctl enable $1 >/dev/null 2>&1
}
svc jupyterlab "JupyterLab" $JETSON_USER "$V/bin/jupyter lab"
if [ "$ROBOT" = jetbot ]; then
  svc jetbot-oled "JetBot OLED status" $JETSON_USER "$V/bin/python -u $H/jetbot/oled_stats.py"
  svc jetbot-teleop "JetBot gamepad control" $JETSON_USER "$V/bin/python -u $H/jetbot/teleop.py"
fi
# GPU/EMC follow the load (idle: GPU 77 MHz, EMC 204 MHz; busy: 640 / 1600 MHz); CPU cap: nano-power
install -m 755 $REPO/rootfs/tegra-dvfs.py $R/usr/local/sbin/tegra-dvfs.py
cat > $R/etc/systemd/system/tegra-dvfs.service <<X
[Unit]
Description=GPU/EMC clock scaling by load
After=tegra-clocks.service
Wants=tegra-clocks.service
[Service]
ExecStart=/usr/bin/python3 -u /usr/local/sbin/tegra-dvfs.py
KillSignal=SIGINT
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
X
chr systemctl enable tegra-dvfs >/dev/null 2>&1
# update check: daily look for a newer GitHub release, shown at login; sudo nano-update install applies it
install -m 755 $REPO/rootfs/nano-update $R/usr/local/sbin/
install -m 644 $REPO/rootfs/nano-update.service $REPO/rootfs/nano-update.timer $R/etc/systemd/system/
chr systemctl enable nano-update.timer >/dev/null 2>&1
printf '%s\n%s\n' "$TAG" "$SLUG" > $R/etc/jetson-nano-version
# 4 GB swap (PyTorch training), server mode (no GUI installed)
[ -f $R/swapfile ] || { fallocate -l 4G $R/swapfile; chmod 600 $R/swapfile; mkswap $R/swapfile >/dev/null; }
grep -q swapfile $R/etc/fstab 2>/dev/null || echo "/swapfile none swap sw 0 0" >> $R/etc/fstab
echo vm.swappiness=10 > $R/etc/sysctl.d/90-swap.conf
chr systemctl set-default multi-user.target >/dev/null 2>&1
cat > $R/etc/update-motd.d/99-jetson-nano <<'X'
#!/bin/sh
echo " Jetson Nano: Ubuntu 26.04, Linux $(uname -r), CUDA 12.6, PyTorch 2.14, TensorRT 8 (nano-trt)"
echo " CPU clock: $(nano-power status | head -1)   change: sudo nano-power safe | max | test"
[ -f /etc/apt/preferences.d/jetson-nano-protect ] && echo " Update lock on: apt upgrade and pip install are safe." \
  || echo " No update lock: do not install kernel/NVIDIA/CUDA packages or torch from PyPI."
echo " Never: do-release-upgrade (new Python breaks the PyTorch build)."
[ -f /var/lib/nano-update/latest ] && echo " Update available: $(cat /var/lib/nano-update/latest)   show: nano-update   install: sudo nano-update install"
X
chmod 755 $R/etc/update-motd.d/99-jetson-nano

step "Update lock: $([ "$UPDATE_LOCK" = 1 ] && echo on || echo "skipped (UPDATE_LOCK=0)")"
if [ "$UPDATE_LOCK" = 1 ]; then
  # apt in Ubuntu 26.04: never install kernels, bootloaders, NVIDIA desktop drivers or Ubuntu's CUDA 13
  cat > $R/etc/apt/preferences.d/jetson-nano-protect <<X
Package: linux-image-* linux-modules-* linux-generic* linux-headers-generic flash-kernel grub-* u-boot*
Pin: release *
Pin-Priority: -1

Package: nvidia-l4t-* nvidia-driver-* nvidia-dkms-* nvidia-cuda-toolkit nvidia-cuda-dev nvidia-jetpack*
Pin: release *
Pin-Priority: -1
X
  # pip in ~/torch-venv: keep the sm_53 PyTorch build (PyPI wheels have no kernels for this GPU)
  printf 'torch==2.14.1a0+git5c48869\ntorchvision==0.29.2+f122815\n' > $R$V/constraints.txt
  printf '[install]\nconstraint = %s/constraints.txt\n' $V > $R$V/pip.conf
  chr chown $JETSON_USER:$JETSON_USER $V/constraints.txt $V/pip.conf
  # L4T: an "apt upgrade" there could rewrite extlinux.conf and remove the Ubuntu 26.04 boot entry
  apt-mark hold $(dpkg-query -W -f='${Package} ${Status}\n' 'nvidia-l4t-*' 2>/dev/null | grep ' installed$' | cut -d' ' -f1) >/dev/null
fi
rm -f $R/etc/resolv.conf; mv $R/etc/resolv.conf.jn $R/etc/resolv.conf

step "Boot entry: $([ "$SET_DEFAULT" = 1 ] && echo "Ubuntu 26.04 is the default" || echo "L4T stays the default")"
[ "$SET_DEFAULT" = 1 ] && sed -i 's/^DEFAULT .*/DEFAULT u2604/' $E
grep -n "^DEFAULT\|^LABEL" $E
[ -n "$PM" ] && nvpmodel -m "$PM" </dev/null >/dev/null 2>&1 || true   # L4T power mode as before
sync; settings
cat <<X

${B}Done.${N} Reboot to start Ubuntu 26.04 (first boot about 40 s):  sudo reboot
  Log in:      ssh $JETSON_USER@jetson.local   (the IP address may differ from L4T's)
  JupyterLab:  http://jetson.local:8888 (same password)        Log of this installation: $LOG
  Check GPU:   ~/torch-venv/bin/python -c "import torch; print(torch.cuda.is_available())"
  CPU clock:   sudo nano-power status | safe | max | test   (test = 5 min load test, then full clock)
  TensorRT:    sudo nano-trt build model.onnx model.engine; JetBot detector: ~/jetbot/build_detector.sh
  Back to L4T: set DEFAULT primary in /boot/extlinux/extlinux.conf (or restore $E.bak-jn);
               inside Ubuntu 26.04 the L4T system is mounted at /media/l4t.
X
