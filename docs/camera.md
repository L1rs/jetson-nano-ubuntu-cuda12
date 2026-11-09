# Camera (IMX219)

Hardware: IMX219 sensor on the CSI camera connector (CSI A, 2 lanes).

## Kernel side

The mainline drivers `tegra-video` (`VIDEO_TEGRA`) and `imx219` (`VIDEO_IMX219`) work without driver patches. The device tree include `kernel/nano-imx219.dtsi` describes the sensor (I2C bus 2, address 0x10, reset/XCLR GPIO, 24 MHz fixed clock, CSI A channel with `nvidia,mipi-calibrate`, 456 MHz) and fixes the L4T camera I2C mux to CAM0. The values come from the L4T device tree.

The result is `/dev/video0` (video-centric; sensor controls are on the video node) with raw Bayer RGGB 8/10 bit at 3280x2464, 1920x1080, 1640x1232 and 640x480. `v4l2-ctl --stream-mmap` delivers 60 fps at 1640x1232. At each stream start there is usually one `frame start syncpt timeout` message; after that the stream is stable. There is no ISP: the Tegra VI delivers raw Bayer, which is why the colour work is done in software.

## `nanocam` (colour in software)

`camera/nanocam.py` is installed to `/opt/nanocam` (importable as `nanocam`, command `nanocam`):

```python
from nanocam import NanoCam
cam = NanoCam(224, 224)      # or NanoCam(640, 480)
frame = cam.read()           # BGR uint8, always the newest frame
cam.close()
```

CLI: `nanocam --size 640x480 --out x.jpg` (other options: `--frames`, `--flip`).

Pipeline: capture at 1640x1232 RGGB8 (full field of view) in a reader thread, 2x2 quad debayer (R, mean of both G, B) to 820x616, resize to the target size, then in linear light black level, lens shading correction and colour matrix taken from the NVIDIA ISP file, grey-world auto white balance, sRGB gamma. Auto exposure adjusts the V4L2 controls `exposure` and `analogue_gain`.

Speed: 30 fps at 224x224 and 640x480 (sensor limited to 30 fps); the CPU manages about 39 / 29 fps at 4 x 918 MHz.

## ISP file

Lens shading and colour matrix are read from `camera_overrides.isp` (4000 K surface). `install.sh` copies it from your own L4T install (`/var/nvidia/nvcam/settings/camera_overrides.isp`) to `/opt/nanocam`. The file is not distributed in this repository. `nanocam` also looks at `/media/l4t/var/nvidia/nvcam/settings/camera_overrides.isp`. Without the file the colours are uncorrected. The ISP file on the original image came from Waveshare.

## Limitations

- Mixed light gives a slightly bluish image; lens shading is only calibrated for 4000 K.
- No highlight protection in auto exposure.
