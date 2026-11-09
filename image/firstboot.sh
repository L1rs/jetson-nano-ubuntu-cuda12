#!/bin/sh
# SPDX-License-Identifier: MIT
# Runs once in L4T on the first boot of the ready-made SD card image (jn-firstboot.service):
#   1. grows the APP partition and its file system to the whole SD card (NVIDIA's nvresizefs.sh, keeps the PARTUUID)
#   2. new SSH host keys for this device (L4T and Ubuntu 26.04 get the same ones)
#   3. this board's trained RAM timing table into the Ubuntu 26.04 device tree. The bootloader trains the table on
#      every board; the image must not use the table of the board it was made on.
#   4. Ubuntu 26.04 becomes the boot default, the service removes itself, reboot.
# If no trained table is found, L4T stays the default (log: /var/log/jn-firstboot.log).
set -e
exec >> /var/log/jn-firstboot.log 2>&1; echo "== $(date)"
D=/opt/jn-firstboot; DTB=/boot/mainline/tegra210-p3450-0000.dtb; E=/boot/extlinux/extlinux.conf; U=/opt/u2604
/usr/lib/nvidia/resizefs/nvresizefs.sh || echo "NOTE: could not grow the partition"
df -h /
rm -f /etc/ssh/ssh_host_*; ssh-keygen -A; cp -a /etc/ssh/ssh_host_* $U/etc/ssh/
dtc -q -I fs -O dts /proc/device-tree > $D/l4t-live.dts 2>/dev/null || true
ok=; for rc in 0x00 0x01 0x02 0x03; do   # only the table matching this board's RAM code is trained
  python3 $D/emc-table.py $D/l4t-live.dts $rc $D/emc.bin && ok=$rc && break
done
[ -n "$ok" ] || { echo "no trained EMC table found, L4T stays the default"; exit 1; }
echo "RAM code $ok"
fdtput -t bx $DTB /external-memory-controller@7001b000 nvidia,emc-table $(od -An -v -tx1 $D/emc.bin)
sed -i 's/^DEFAULT .*/DEFAULT u2604/' $E
systemctl disable jn-firstboot.service; rm -f /etc/systemd/system/jn-firstboot.service
echo "done, rebooting into Ubuntu 26.04"; sync; reboot
