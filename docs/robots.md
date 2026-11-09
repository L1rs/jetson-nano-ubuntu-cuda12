# Robots: JetBot and JetRacer

`install.sh` copies both software sets to the home directory of the new user. `ROBOT=jetbot` (default is `none`; the installer asks) additionally enables the OLED and gamepad services. I2C1 (header pins 3/5, controller `7000c400.i2c`) is enabled in the device tree; the bus number varies, so the software looks it up by controller name. The user must be in groups `i2c` and `input` (set by the installer).

## JetBot (Waveshare board)

I2C devices seen on bus 0 (pins 3/5): `0x3c` OLED, `0x48` ADS1115, `0x60` PCA9685, `0x70` (the PCA9685 all-call address, not a separate device).

`jetbot/jetbot_hw.py`:
- **Motors:** PCA9685 at 0x60 (1600 Hz) driving a TB6612. Left motor channels 1/0, right motor channels 2/3, as in the Waveshare software.
- **Battery:** ADS1115 at 0x48, input AIN0, +-4.096 V range, through a 1:4 divider (voltage = reading x 4). Measured 11.99-12.08 V on a fresh pack of 3 x 18650.
- **OLED:** SSD1306 128x32 at 0x3c, text rendered with Pillow's bitmap font.

### Services

| Service | What it does |
|---|---|
| `jetbot-oled` | shows IP address, battery voltage and percentage, CPU load and temperature, RAM use; refresh every 2 s (`oled_stats.py`) |
| `jetbot-teleop` | USB gamepad control (`teleop.py`) |
| `jupyterlab` | notebooks on port 8888 |

**Gamepad:** use the PC mode with **two LEDs lit** (analog sticks); in other modes the sticks deliver only 0 or full deflection. The gamepad tested was a ShanWan PC/PS3/Android pad (axes 0..255). Left stick Y = throttle with a quadratic curve (fine control around the centre), right stick X = steering (60 % share), top speed 0.5 by default; options `--max`, `--turn`, `--expo`, `--steer`, optional dead-man button `--deadman`, `--probe` prints events without driving. Dead zone 0.08. Motors stop on exit, error or connection loss, and the service reconnects automatically after a mode change or power-off of the pad. Xbox mode needs `xpad`, which is not built.

While a notebook uses the robot, `jetbot-teleop` pauses: `jetbot.Robot()` writes its PID to `/dev/shm/jetbot-notebook`, and teleop stays off as long as that process exists.

### Notebooks and compatibility package

`~/jetbot/notebooks` contains the Waveshare/NVIDIA JetBot notebooks (MIT, (c) NVIDIA): `basic_motion`, `teleoperation`, `collision_avoidance` (data collection, training, live demo) and `road_following` (data collection, training, live demo). `object_following` (live demo) is included and uses `jetbot.ObjectDetector`. In `collision_avoidance` (training and live demo) and `object_following` (collision model), alexnet was replaced by resnet18, `pretrained=True/False` by `weights='DEFAULT'/None`, and `torch.load` uses `map_location='cpu'`. Models trained with the old AlexNet notebooks are not compatible; retrain them.

The package `jetbot/jetbot/` (on the venv path via a `.pth` file) replaces NVIDIA's:
- `Robot` / `Motor` on the PCA9685 driver, `Camera` on `nanocam`, `Heartbeat`, `bgr8_to_jpeg`
- `Gamepad` instead of the browser `ipywidgets.Controller`: it reads the USB pad on the Jetson. Axes `axes[0..3]` = LX, LY, RX, RY in -1..1; buttons use the same layout as the widget (codes 288.., D-pad 12-15).
- `ObjectDetector` on SSDlite320, see below.

Tested without moving the robot: camera 224x224, robot lock, gamepad, battery reading, AlexNet training (0.84 s per batch of 8) and inference (26.9 fps; measured before the notebooks were changed to resnet18). The notebooks were not clicked through in a browser.

## JetRacer

Hardware: PCA9685 at `0x40` (steering on channel 0, throttle on channel 1). This is the address the JetRacer code expects; on the Waveshare JetBot board this chip is absent, so the JetRacer part needs a JetRacer board.

Files (copied to `~/jetracer`):
- `jetracer/nvidia_racecar.py`: replaces the Blinka/ServoKit class `NvidiaRacecar` (which does not run on mainline) with direct `smbus2` access, 50 Hz, pulse 1500 +- 750 us like ServoKit. It imports the base class `Racecar` from `jetracer/racecar.py` (unchanged from NVIDIA-AI-IOT/jetracer, MIT); `install.sh` copies both to `~/jetracer/jetracer/`.
- `jetracer/camera.py`: replaces `jetcam`: `CSICamera` on NanoCam, `bgr8_to_jpeg`, `ClickableImageWidget` via anywidget.
- `jetracer/road_following.py`: resnet18 FP16 in plain PyTorch with NanoCam at 224x224. `python road_following.py [--drive] [--throttle 0.0] [--secs 10] [--gain 0.75] [--bias 0.0] [--model PATH]`. Without `--drive` it only measures. Camera in its own thread: 17.3 fps end to end (11.9 fps without the thread). You need a trained `road_following_model.pth`.
- `jetracer/jetracer-port-notebooks.py`: converts the NVIDIA JetRacer notebooks (`basic_motion`, `interactive_regression`, `road_following`, `road_following_live`) to the replacements above (originals kept as `*.orig.ipynb`; TensorRT steps removed). Not run by the installer.
- `jetracer/donkey-nano_parts.py`: Donkeycar parts (tested with Donkeycar 5.4.0, updated from 5.0.0; installed with `pip install --ignore-requires-python donkeycar==5.4.0` because 5.4 declares Python < 3.14 but runs on 3.14): a `PCA9685` part on smbus2 and `NanoCamPart` (RGB). Copy to `~/mycar/nano_parts.py` and reference it from `manage.py`/`myconfig.py` (160x120, 20 Hz in the tested setup). Donkeycar itself is not installed by `install.sh`. The autopilot (TensorFlow) is not set up.

**Safety.** Test with the **wheels lifted**. `road_following.py` does not drive without `--drive`. `donkey-nano_parts.py` starts with `THROTTLE_LOCK = True`, which holds the throttle channel at neutral; set it to `False` only for driving. Steering and neutral throttle were verified through register read-back; driving on the ground was not tested.

## Object following

`jetbot.ObjectDetector()` replaces the TensorRT SSD engine of the original JetBot with torchvision's
`ssdlite320_mobilenet_v3_large` (COCO weights, downloaded on first use). The output is the same as the original: per image a list of
`{'label': COCO id (1 = person), 'confidence': 0..1, 'bbox': [x0, y0, x1, y1] relative}`, so
`notebooks/object_following/live_demo.ipynb` runs unchanged apart from the constructor.

- With `~/jetbot/ssdlite320.engine` the backbone and head run in TensorRT 8.0 (see [tensorrt.md](tensorrt.md)). Build the engine once with `~/jetbot/build_detector.sh`. It takes about 10 minutes and asks for the sudo password. Restart running notebooks afterwards.
- Without the engine, backbone and head run in PyTorch FP16.
- The postprocessing was rewritten: top 200 over all anchors x classes and one `batched_nms` (score threshold, `nms_thresh` of the model, 20 detections), instead of torchvision's per-class loop over 90 classes.

Speed at CPU 918 MHz (`nano-power safe`), 300x300 input: old PyTorch path 5.4 fps, new PyTorch path 12.1 fps, TensorRT 16.7 fps (17.4 fps with the live camera). The same test image gives the same detection in both paths (dog, confidence 0.82 TensorRT, 0.83 PyTorch, identical box). Earlier versions of this page gave 8.8 fps and 6.8 fps; that was the old code at CPU 1912 MHz.
