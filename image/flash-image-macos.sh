#!/bin/sh
# SPDX-License-Identifier: MIT
# macOS: writes the ready-made image (.img.xz) to an SD card. Usage: sh flash-image-macos.sh <image.img.xz> disk4
# (balenaEtcher or Raspberry Pi Imager "Use custom" do the same with a GUI.)
set -e
I=${1:?image .img.xz}; D=${2:?disk, e.g. disk4}
info=$(diskutil info $D)
echo "$info" | grep -q "Device Location: *External" || { echo "$D is not an external disk - stopped" >&2; exit 1; }
size=$(echo "$info" | sed -n 's/.*Disk Size: .*(\([0-9]*\) Bytes).*/\1/p')
need=$(xz --robot -l "$I" | awk '/^totals/{print $5}')
[ "$size" -ge "$need" ] || { echo "$D is too small ($size < $need bytes) - stopped" >&2; exit 1; }
[ "$size" -le 300000000000 ] || { echo "$D is larger than 300 GB, probably not an SD card - stopped" >&2; exit 1; }
echo "Target: /dev/$D, $(echo "$info" | sed -n 's/.*Media Name: *//p'), $size bytes. ALL DATA ON IT WILL BE OVERWRITTEN."
diskutil unmountDisk force /dev/$D
xz -dc "$I" | sudo dd of=/dev/r$D bs=4m
sync; diskutil eject /dev/$D; echo "DONE: card written and ejected."
