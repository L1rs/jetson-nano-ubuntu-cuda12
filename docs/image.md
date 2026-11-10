# Ready-made SD card image

The image is an SD card made with `install.sh` on NVIDIA's JetPack 4.6.1 image: L4T 32.7.1 plus Ubuntu 26.04 in `/opt/u2604`. User `jetson`, password `jetson` in both systems (change it). Size: about 6.7 GB download (`.img.xz`), 25.5 GB written, so it needs an SD card of **32 GB or more**.

Download v0.2.0: [jetson-nano-ubuntu-26.04-v0.2.0.img.xz](https://drive.google.com/file/d/1KbnhAZUMzqA1VpW7FEuMFEQuR4TZ2x3T/view?usp=sharing), [checksum file](https://drive.google.com/file/d/1nOEWWLh2C8F0RUmd4KOedo6E30KMWA_2/view?usp=sharing) (SHA-256 `d4bdefab4a9329881b238ea7acf39db422725f173a74f5da1183b5caf161e1a8`). GitHub release files are limited to 2 GB, so the image is hosted on Google Drive. Newer releases do not come with a new image: flash v0.2.0, then run `sudo nano-update install`.

## Using it

1. Write the image to the card: balenaEtcher, Raspberry Pi Imager ("Use custom"), or on macOS `sh image/flash-image-macos.sh <image.img.xz> disk4`.
2. Put the card into the Nano, connect ethernet, power on. The first boot takes about 2 minutes and reboots once by itself.
3. `ssh jetson@jetson.local`, JupyterLab on `http://jetson.local:8888`.

## First boot

The image starts L4T once. `jn-firstboot.service` runs `/opt/jn-firstboot/firstboot.sh`:

1. grows the APP partition and its file system to the whole SD card (NVIDIA's `nvresizefs.sh`; the partition keeps its PARTUUID, which the Ubuntu 26.04 boot entry uses),
2. creates new SSH host keys for this device (the same ones in L4T and Ubuntu 26.04),
3. reads this board's trained RAM timing table (EMC table) from the running L4T device tree (`kernel/emc-table.py`) and writes it into `/boot/mainline/tegra210-p3450-0000.dtb`. The bootloader trains the table on every board and the values differ between boards and boots, so the image must not use the table of the board it was made on,
4. makes Ubuntu 26.04 the boot default, removes the service and reboots.

If no trained table is found, L4T stays the default. Log: `/var/log/jn-firstboot.log` in L4T (`/media/l4t/var/log/jn-firstboot.log` from Ubuntu 26.04).

## Making the image (maintainers)

1. Fresh card with NVIDIA's JetPack 4.6.1 image, first setup (user `jetson`), `sudo ./install.sh -y`, reboot, check.
2. In Ubuntu 26.04: `sudo image/clean-for-image.sh`. It removes SSH host keys, machine-id, DHCP leases, logs, shell history, caches and the installer downloads in both systems, arms the first boot (`image/arm-firstboot.sh`: L4T becomes the default) and powers off. It lists the network profiles: there must be no WLAN profile.
3. macOS: `sh image/read-card-macos.sh disk4 <dir>` reads `head.img` (before the APP partition) and `app.img` (about 64 GB of free space needed).
4. Linux (e.g. a container with `e2fsprogs gdisk zerofree xz-utils` and `<dir>` mounted): `sh image/shrink-image.sh <dir> jetson-nano-ubuntu-26.04-v$(cat VERSION)`. It shrinks the file system to its minimum, zeroes the free blocks, writes the partition table with the same name, type and PARTUUID and compresses to `.img.xz` plus `.sha256`.
5. Test: write the image to a card, boot, check `/media/l4t/var/log/jn-firstboot.log`, EMC rates, `df -h /`.

Tested with v0.2.0 on a 64 GB card: the first boot grew the file system to 59 GB, created new SSH keys, wrote the table (RAM code 0x00) and booted Ubuntu 26.04; all services ran, EMC 204/1600 MHz, CUDA and JupyterLab ok.

