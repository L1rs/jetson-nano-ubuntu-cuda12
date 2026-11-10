# Updates

Installed systems (from `install.sh` or from the SD card image) can follow the GitHub releases of this project.

## For users

- A daily timer (`nano-update.timer`) asks GitHub whether a newer release exists. If so, the login message shows `Update available: vX.Y.Z`.
- `nano-update` shows the installed and the newest version and the release notes.
- `sudo nano-update install` downloads the newest release and runs its `update.sh`. Log: `/var/log/nano-update.log`.

What an update brings (each step only adds what is missing, so it can run again at any time):

| Area | What happens |
|---|---|
| Downloads | Kernel and PyTorch wheels (only if the release has newer ones) are downloaded and checked against `SHA256SUMS` **before anything is changed**. |
| Ubuntu packages | Packages of the release (`rootfs/packages.txt`) and the CUDA runtime (`rootfs/cuda-packages.txt`) that are missing are added. Installed packages are not upgraded or removed. |
| Python | New PyTorch/torchvision build if the release has one (the update lock pin moves along). Missing packages from `rootfs/venv-requirements.txt` are added; other packages are not touched. |
| Tools | `nano-power`, `nano-update`, `tegra-dvfs`, TensorRT bridge in `/opt/nanotrt`, systemd units, small system fixes of the release. |
| Robot software | JetBot/JetRacer Python code is replaced, new notebooks are added. **Your notebooks, models and settings are not touched.** |
| Kernel | A new kernel or a new build of its modules is installed; the previous one stays as boot entry `u2604-prev` (serial console). The device tree stays, because it contains this board's RAM timing table. Reboot afterwards. |
| Version | `/etc/jetson-nano-version` is written last. If an update stops (`ERROR in update step N`), run it again: `sudo FORCE=1 nano-update install`. |

Not covered: Ubuntu's own updates (`apt upgrade`, below), Python packages you installed yourself, the device tree and initramfs, L4T, a new CUDA major version or a new Ubuntu release (those need a new installation).

- Installed version and repository: `/etc/jetson-nano-version`. From a git checkout you can also run `sudo ./update.sh`.
- Ubuntu packages are updated as usual with `sudo apt update && sudo apt upgrade` (protected by the update lock, see [install.md](install.md)).

## For maintainers: making a release

1. Change the code, write the changes in `CHANGELOG.md`, raise `VERSION` (for example `0.2.1`).
2. New Ubuntu package: add it to `rootfs/packages.txt`; new Python package: `rootfs/venv-requirements.txt` (both are used by the installer and by `update.sh`). Other changes for installed systems (new service, config fix): add them to step 4 of `update.sh`. Every step must be safe to run more than once. `update.sh` must stay runnable from older `nano-update` versions (it restarts itself in bash).
3. New kernel: change `KVER` in `install.sh`, build it (`kernel/`), put `linux-$KVER-t210-jetson-nano.tar.gz` into `dist/`. Changed modules with the same kernel version (for example `nvgpu.ko`): raise `KBUILD` in `install.sh` and write it to `lib/modules/$KVER/nano-build` in the tarball; `update.sh` reinstalls the kernel package when that file differs.
4. `cd dist && sha256sum * > SHA256SUMS`.
5. Create the GitHub release with tag `v$(cat VERSION)`, the CHANGELOG section as text and **all files from `dist/`** attached (kernel, PyTorch wheels, SHA256SUMS): `install.sh` downloads the files of its own release tag.

`nano-update` uses the GitHub API (`/repos/<owner>/<repo>/releases/latest`), so only published (not draft or pre-release) releases count.
