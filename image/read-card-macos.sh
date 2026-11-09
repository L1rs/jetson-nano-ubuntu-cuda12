#!/bin/sh
# SPDX-License-Identifier: MIT
# macOS: reads a prepared SD card (after clean-for-image.sh) into <dir>/head.img (everything before the APP
# partition) and <dir>/app.img (the APP partition). Next: shrink-image.sh in Linux.
# Usage: sh read-card-macos.sh disk4 "/Volumes/SSD/jetson-image"     (asks for the sudo password)
set -e
D=${1:?disk, e.g. disk4}; O=${2:?output directory}
info=$(diskutil info $D)
echo "$info" | grep -q "Device Location: *External" || { echo "$D is not an external disk" >&2; exit 1; }
start=$(diskutil info ${D}s1 | sed -n 's/.*Partition Offset:.*(\([0-9]*\) 512-Byte.*/\1/p')
[ -n "$start" ] || { echo "no partition 1 on $D" >&2; exit 1; }
echo "Reading $D ($(echo "$info" | sed -n 's/.*Media Name: *//p')): APP starts at sector $start"
mkdir -p "$O"; diskutil unmountDisk force /dev/$D
sudo dd if=/dev/r$D of="$O/head.img" bs=512 count=$start
sudo dd if=/dev/r${D}s1 of="$O/app.img" bs=4m
sudo chown "$(id -u)" "$O/head.img" "$O/app.img"; diskutil eject /dev/$D
echo "done: $O/head.img $O/app.img"
