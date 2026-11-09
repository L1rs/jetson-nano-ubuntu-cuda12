#!/bin/bash
# SPDX-License-Identifier: MIT
# update.sh: brings a running Ubuntu 26.04 system of this project (from install.sh or the SD card image) to the state
# of this release. Normally started by "sudo nano-update install"; can also be run from a git checkout: sudo ./update.sh
# Safe to run again at any time: every step only adds what is missing or replaces files of this project.
#   1. download and verify everything first (kernel, PyTorch wheels; only if newer) - nothing is changed before that
#   2. Ubuntu packages and CUDA runtime of this release: missing ones are added (apt), nothing is removed
#   3. ~/torch-venv: new PyTorch/torchvision wheels if the release has a newer build; missing Python packages are added
#   4. tools in /usr/local/sbin, /opt/nanotrt, systemd units, small system fixes of this release
#   5. robot software in ~/jetbot and ~/jetracer (Python code is replaced; notebooks: only new ones are added)
#   6. kernel, if the release has a newer one (the previous one stays bootable as boot entry "u2604-prev")
#   7. version in /etc/jetson-nano-version (written last: an interrupted update simply runs again)
# Not touched: your notebooks, settings, other Python packages, the device tree (board specific), L4T.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # older nano-update versions start it with sh
set -Eeuo pipefail
HERE=$(dirname "$(readlink -f "$0")"); TAG=v$(cat "$HERE/VERSION")
val() { sed -n "s/^$1=//p" "$HERE/install.sh" | head -1; }
KVER=$(sed -n 's/^export KVER=//p' "$HERE/install.sh"); TORCH_WHL=$(val TORCH_WHL); VISION_WHL=$(val VISION_WHL)
SLUG=$(sed -n 2p /etc/jetson-nano-version 2>/dev/null || true)
RELEASE_URL=${RELEASE_URL:-https://github.com/$SLUG/releases/download/$TAG}
B=/media/l4t/boot/mainline; E=/media/l4t/boot/extlinux/extlinux.conf
V=$(ls -d /home/*/torch-venv 2>/dev/null | head -1 || true); H=${V%/torch-venv}; U=${H##*/}
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
[ -d $B ] && [ -n "$V" ] || { echo "run this inside the Ubuntu 26.04 system of this project" >&2; exit 1; }
LOG=/var/log/nano-update.log; trap '' HUP; exec > >(tee -a --output-error=warn $LOG) 2>&1
trap 'echo; echo "ERROR in update step ${S:-0} (update.sh line $LINENO). Log: $LOG"; echo "Nothing is lost: run sudo nano-update install again (FORCE=1 to repeat the same version)."' ERR
echo "== $(date) updating to $TAG"
pyver() { "$V/bin/python" -c 'import importlib.metadata as m, sys; print(m.version(sys.argv[1]))' "$1" 2>/dev/null || echo none; }
NEW_TORCH=$(echo "$TORCH_WHL" | cut -d- -f2); NEW_VISION=$(echo "$VISION_WHL" | cut -d- -f2)
[ "$(pyver torch)" != "$NEW_TORCH" ] || [ "$(pyver torchvision)" != "$NEW_VISION" ] && WHEELS=1 || WHEELS=
[ -d /usr/lib/modules/$KVER ] && KERNEL= || KERNEL=1

S=1; echo "== 1. Download and verify${KERNEL:+ kernel $KVER}${WHEELS:+ PyTorch $NEW_TORCH}"
T=$(mktemp -d /var/tmp/nano-update.XXXX); trap 'rm -rf $T' EXIT
need=(); [ -n "$KERNEL" ] && need+=(linux-$KVER-t210-jetson-nano.tar.gz); [ -n "$WHEELS" ] && need+=("$TORCH_WHL" "$VISION_WHL")
if [ ${#need[@]} -gt 0 ]; then
  for f in SHA256SUMS "${need[@]}"; do curl -fsSL --retry 3 -m 900 -o "$T/$f" "$RELEASE_URL/$f"; done
  (cd $T && sha256sum -c --ignore-missing SHA256SUMS)
else echo "nothing to download"; fi

S=2; echo "== 2. Ubuntu packages and CUDA runtime (missing ones are added)"
for i in $(seq 60); do fuser /var/lib/dpkg/lock* >/dev/null 2>&1 || break; echo "waiting for another apt to finish"; sleep 10; done
export DEBIAN_FRONTEND=noninteractive
dpkg --configure -a
missing() { for p in $(grep -v '^#' "$1"); do dpkg-query -W -f='${Status}' $p 2>/dev/null | grep -q 'ok installed' || echo $p; done; }   # installed ones are left as they are
apt-get update -qq || echo "NOTE: apt-get update reported errors, trying anyway"
m=$(missing "$HERE/rootfs/packages.txt"); [ -z "$m" ] || { echo "adding: $m"; apt-get install -y -qq --no-install-recommends $m >/dev/null; }
missing=$(missing "$HERE/rootfs/cuda-packages.txt")
if [ -n "$missing" ]; then echo "adding: $missing"   # Jetson repo only for this; never pull nvidia-l4t-* (those need the L4T kernel)
  J=/etc/apt/sources.list.d/jetson-nano-update.list
  echo "deb [trusted=yes arch=arm64] https://repo.download.nvidia.com/jetson/common r36.4 main" > $J
  apt-get update -qq || true
  if apt-get install -s --no-install-recommends $missing | grep -q nvidia-l4t; then rm -f $J; echo "CUDA packages would need nvidia-l4t-*"; false; fi
  apt-get install -y -qq --no-install-recommends $missing >/dev/null || { rm -f $J; false; }
  rm -f $J; apt-get update -qq || true; ldconfig
fi

S=3; echo "== 3. Python environment $V"
if [ -n "$WHEELS" ]; then   # the update lock pins torch: move the pin to the new build first
  printf 'torch==%s\ntorchvision==%s\n' "$NEW_TORCH" "$NEW_VISION" > $V/constraints.txt; chown $U:$U $V/constraints.txt
  cp "$T/$TORCH_WHL" "$T/$VISION_WHL" /var/tmp/; chmod 644 "/var/tmp/$TORCH_WHL" "/var/tmp/$VISION_WHL"
  runuser -u $U -- $V/bin/pip install -q "/var/tmp/$TORCH_WHL" "/var/tmp/$VISION_WHL"
  rm -f "/var/tmp/$TORCH_WHL" "/var/tmp/$VISION_WHL"
fi
runuser -u $U -- $V/bin/pip install -q -r /dev/stdin < "$HERE/rootfs/venv-requirements.txt"   # only adds what is missing
runuser -u $U -- $V/bin/python -c "import torch, torchvision, numpy, cv2, onnx, jupyterlab; print('Python environment ok: torch', torch.__version__)"

S=4; echo "== 4. Tools, TensorRT bridge, services, system fixes"
install -m 755 "$HERE/rootfs/nano-power" "$HERE/rootfs/nano-update" "$HERE/rootfs/tegra-dvfs.py" /usr/local/sbin/
install -m 644 "$HERE/rootfs/nano-update.service" "$HERE/rootfs/nano-update.timer" /etc/systemd/system/
if [ -d /opt/nanotrt ]; then sh "$HERE/tensorrt/build.sh" >/dev/null; fi
# fixes from build-rootfs.sh that older installations do not have yet (each one is idempotent)
touch /etc/NetworkManager/conf.d/10-globally-managed-devices.conf   # 0.2.0: ethernet managed without netplan
systemctl enable avahi-daemon >/dev/null 2>&1 || true                # 0.2.0: ssh jetson@jetson.local

S=5; echo "== 5. Robot software in $H (Python code is replaced, notebooks: only new ones are added)"
cp "$HERE"/jetbot/*.py "$HERE"/jetbot/*.sh $H/jetbot/; cp "$HERE"/jetbot/jetbot/*.py $H/jetbot/jetbot/
cp -r --update=none "$HERE/jetbot/notebooks/." $H/jetbot/notebooks/
cp "$HERE"/jetracer/nvidia_racecar.py "$HERE"/jetracer/racecar.py "$HERE"/jetracer/camera.py $H/jetracer/jetracer/
cp "$HERE/jetracer/road_following.py" $H/jetracer/; install -m 755 "$HERE/camera/nanocam.py" /opt/nanocam/
chown -R "$U:$U" $H/jetbot $H/jetracer

S=6; echo "== 6. Kernel $KVER"
if [ -z "$KERNEL" ]; then echo "already installed"; else
  tar xzf $T/linux-$KVER-t210-jetson-nano.tar.gz -C $T
  cp $B/Image $B/Image-prev                                # previous kernel stays bootable
  grep -q "^LABEL u2604-prev" $E || { echo; awk '/^LABEL /{p=($2=="u2604")} p' $E | sed \
    's/^LABEL u2604$/LABEL u2604-prev/; s/MENU LABEL .*/MENU LABEL Ubuntu 26.04 (previous kernel)/; s#/boot/mainline/Image$#/boot/mainline/Image-prev#'; } >> $E
  cp -a $T/lib/modules/$KVER /usr/lib/modules/; depmod $KVER
  cp $T/boot/mainline/Image $B/Image.new && mv $B/Image.new $B/Image     # device tree stays (board specific)
  REBOOT=1
fi

S=7; echo "== 7. Services and version"
systemctl daemon-reload; systemctl enable --now nano-update.timer >/dev/null 2>&1
systemctl restart tegra-dvfs
for s in jetbot-oled jetbot-teleop; do if systemctl is-enabled -q $s 2>/dev/null; then systemctl restart $s; fi; done
printf '%s\n%s\n' "$TAG" "$SLUG" > /etc/jetson-nano-version; sync
echo "Updated to $TAG.${REBOOT:+ Reboot to start kernel $KVER:  sudo reboot}"
