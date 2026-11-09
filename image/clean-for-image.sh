#!/bin/sh
# SPDX-License-Identifier: MIT
# Run as root in Ubuntu 26.04 right before the SD card is copied into an image. Removes what belongs to this
# device or to the build (both systems: Ubuntu 26.04 = /, L4T = /media/l4t), arms the first boot and powers off.
# Removed: SSH host keys, machine-id, DHCP leases, logs, shell history, caches, downloads of the installer.
# Kept: users (jetson/jetson), installed software, settings, network profiles (check: there should be no WLAN profile).
set -e
HERE=$(dirname "$(readlink -f "$0")"); L=/media/l4t
[ -f $L/etc/nv_tegra_release ] || { echo "L4T not mounted at $L" >&2; exit 1; }
ls $L/etc/NetworkManager/system-connections/ /etc/NetworkManager/system-connections/
for r in / $L; do
  rm -f $r/etc/ssh/ssh_host_* $r/var/lib/NetworkManager/*.lease $r/var/lib/NetworkManager/*lease*
  : > $r/etc/machine-id
  rm -rf $r/root/.bash_history $r/home/*/.bash_history $r/home/*/.cache $r/root/.cache $r/home/*/.local/share/jupyter/runtime \
         $r/var/cache/apt/archives/*.deb $r/var/log/journal/* $r/var/tmp/* $r/home/*/.ipython/profile_default/history.sqlite
  find $r/var/log -type f \( -name '*.gz' -o -name '*.[0-9]' -o -name '*.old' \) -delete
  find $r/var/log -type f -exec truncate -s 0 {} +
done
rm -rf $L/opt/jn-install $L/home/*/jetson-nano-ubuntu-* $L/home/*/install*.log $L/home/*/install.out $L/tmp/*
rm -rf $L/opt/jn-firstboot /var/lib/nano-update/latest   # also board data of earlier test runs
sh $HERE/arm-firstboot.sh
echo "clean. Powering off; then copy the card (see docs/image.md)."
sync; poweroff
