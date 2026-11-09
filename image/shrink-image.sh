#!/bin/sh
# SPDX-License-Identifier: MIT
# Linux (e2fsprogs, gdisk, zerofree, xz-utils): head.img + app.img from read-card-macos.sh -> <name>.img.xz
# The APP file system is shrunk to its minimum and its free blocks are zeroed; the partition entry keeps its
# name, type and unique GUID (PARTUUID, used by the Ubuntu 26.04 boot entry). On the first boot the image
# grows to the whole SD card again (firstboot.sh).
# Usage: sh shrink-image.sh <dir> <name>      e.g. sh shrink-image.sh /work jetson-nano-ubuntu-26.04-v0.2.0
set -e
cd "$1"; N=$2
e2fsck -fy app.img || [ $? -le 1 ]
resize2fs -M app.img
zerofree -v app.img
BS=$(dumpe2fs -h app.img 2>/dev/null | sed -n 's/^Block size: *//p')
BC=$(dumpe2fs -h app.img 2>/dev/null | sed -n 's/^Block count: *//p')
truncate -s $((BS * BC)) app.img
S=$(($(stat -c %s head.img) / 512)); A=$((BS * BC / 512))
i=$(sgdisk -i 1 head.img 2>/dev/null)
TYPE=$(echo "$i" | sed -n 's/^Partition GUID code: \([^ ]*\).*/\1/p'); GUID=$(echo "$i" | sed -n 's/^Partition unique GUID: //p')
NAME=$(echo "$i" | sed -n "s/^Partition name: '\(.*\)'/\1/p"); ATTR=$(echo "$i" | sed -n 's/^Attribute flags: //p')
echo "APP: start $S, $A sectors, name $NAME, type $TYPE, PARTUUID $GUID"
cat head.img app.img > $N.img; truncate -s $(((S + A + 34) * 512)) $N.img     # 34 sectors for the backup GPT
sgdisk -e -d 1 -n 1:$S:$((S + A - 1)) -c 1:"$NAME" -t 1:$TYPE -u 1:$GUID -A 1:=:$ATTR $N.img
sgdisk -v $N.img; sgdisk -i 1 $N.img | grep -E "unique|size"
xz -T0 -6 -f $N.img; sha256sum $N.img.xz > $N.img.xz.sha256; ls -la $N.img.xz
