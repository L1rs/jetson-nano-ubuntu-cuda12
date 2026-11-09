#!/bin/sh
# SPDX-License-Identifier: MIT
# Run as root in Ubuntu 26.04 right before an SD card image is made: L4T becomes the boot default and the
# one-time jn-firstboot.service is armed in L4T (see firstboot.sh). The next boot runs it.
set -e
HERE=$(dirname "$(readlink -f "$0")"); L=/media/l4t
[ -f $L/etc/nv_tegra_release ] || { echo "L4T not mounted at $L" >&2; exit 1; }
mkdir -p $L/opt/jn-firstboot
install -m 755 $HERE/firstboot.sh $L/opt/jn-firstboot/
install -m 644 $HERE/../kernel/emc-table.py $L/opt/jn-firstboot/
install -m 644 $HERE/jn-firstboot.service $L/etc/systemd/system/
ln -sf /etc/systemd/system/jn-firstboot.service $L/etc/systemd/system/multi-user.target.wants/jn-firstboot.service
sed -i 's/^DEFAULT .*/DEFAULT primary/' $L/boot/extlinux/extlinux.conf
grep -n "^DEFAULT" $L/boot/extlinux/extlinux.conf; echo "armed: the next boot runs L4T once, then Ubuntu 26.04"
