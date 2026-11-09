"""jetbot-kompatibles Paket fuer Ubuntu 26.04 / Mainline (Waveshare JetBot-Board).
Gleiche Schnittstelle wie waveshare/jetbot: Robot, Camera, Heartbeat, bgr8_to_jpeg; dazu Gamepad (Ersatz fuer
ipywidgets.Controller, liest das USB-Gamepad am Jetson statt im Browser) und ObjectDetector (torchvision
SSDlite320-MobileNetV3, COCO, gleiche Ausgabe wie das Original; mit TensorRT 8.0, wenn die Engine gebaut ist)."""
import atexit, enum, fcntl, glob, os, select, struct, sys, threading, time
import traitlets
from traitlets.config.configurable import Configurable, SingletonConfigurable

sys.path.insert(0, os.path.expanduser('~/jetbot'))           # jetbot_hw.py
sys.path.insert(0, os.path.expanduser('~/jetracer'))         # jetracer.camera (NanoCam)
from jetbot_hw import Motors, battery_v
from jetracer.camera import CSICamera, bgr8_to_jpeg

LOCK = '/dev/shm/jetbot-notebook'   # solange vorhanden (und PID lebt), faehrt der Dienst jetbot-teleop nicht

class Motor(Configurable):
    value = traitlets.Float()
    alpha = traitlets.Float(default_value=1.0).tag(config=True)
    beta = traitlets.Float(default_value=0.0).tag(config=True)
    def __init__(self, robot, side, *a, **kw):
        super().__init__(*a, **kw); self._r, self._side = robot, side
    @traitlets.observe('value')
    def _v(self, ch):
        self._r._apply()

class Robot(SingletonConfigurable):
    left_motor = traitlets.Instance(Motor)
    right_motor = traitlets.Instance(Motor)
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        open(LOCK, 'w').write(str(os.getpid()))
        self._m = Motors()
        self.left_motor = Motor(self, 'left'); self.right_motor = Motor(self, 'right')
        atexit.register(self._release)
    def _apply(self):
        l, r = self.left_motor, self.right_motor
        self._m.set(l.alpha * l.value + l.beta, r.alpha * r.value + r.beta)
    def _release(self):
        self._m.stop()
        try: os.remove(LOCK)
        except OSError: pass
    def set_motors(self, left_speed, right_speed):
        self.left_motor.value = left_speed; self.right_motor.value = right_speed
    def forward(self, speed=1.0, duration=None): self.set_motors(speed, speed)
    def backward(self, speed=1.0): self.set_motors(-speed, -speed)
    def left(self, speed=1.0): self.set_motors(-speed, speed)
    def right(self, speed=1.0): self.set_motors(speed, -speed)
    def stop(self): self.set_motors(0, 0)

class Camera(SingletonConfigurable):
    value = traitlets.Any()
    width = traitlets.Integer(default_value=224).tag(config=True)
    height = traitlets.Integer(default_value=224).tag(config=True)
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        self._c = CSICamera(width=self.width, height=self.height)
        self.value = self._c.value
        self._c.observe(lambda ch: setattr(self, 'value', ch['new']), names='value')
        self._c.running = True
        atexit.register(self.stop)
    def start(self): self._c.running = True
    def stop(self): self._c.running = False

class Heartbeat(Configurable):   # wie waveshare/jetbot: Browser muss pulseout zurueckspiegeln, sonst 'dead'
    class Status(enum.Enum):
        dead = 0
        alive = 1
    status = traitlets.UseEnum(Status, default_value=Status.dead)
    running = traitlets.Bool(default_value=False)
    period = traitlets.Float(default_value=0.5)
    def __init__(self, *a, **kw):
        import ipywidgets.widgets as widgets
        super().__init__(*a, **kw)
        self.pulseout = widgets.FloatText(value=time.time())
        self.pulsein = widgets.FloatText(value=time.time())
        self.link = widgets.jsdlink((self.pulseout, 'value'), (self.pulsein, 'value'))
        self.start()
    def _run(self):
        while self.running:
            self.status = Heartbeat.Status.dead if self.pulseout.value - self.pulsein.value >= self.period else Heartbeat.Status.alive
            self.pulseout.value = time.time(); time.sleep(self.period)
    def start(self):
        if not self.running:
            self.running = True; threading.Thread(target=self._run, daemon=True).start()
    def stop(self): self.running = False

class _Val(traitlets.HasTraits):
    value = traitlets.Float()
    pressed = traitlets.Bool()

class Gamepad(traitlets.HasTraits):
    """Wie ipywidgets.Controller (Standard-Layout): axes[0..3] = LX, LY, RX, RY in -1..1; buttons[0..11] = Tasten
    = Tastencodes 288..299 (BTN_TRIGGER ff.), buttons[12..15] = Steuerkreuz hoch/runter/links/rechts. Gamepad im Modus mit 2 LEDs."""
    connected = traitlets.Bool(False)
    def __init__(self, index=0):
        super().__init__()
        self.axes = [_Val() for _ in range(4)]; self.buttons = [_Val() for _ in range(16)]
        threading.Thread(target=self._loop, daemon=True).start()
    def _set(self, b, on):
        self.buttons[b].value = 1.0 if on else 0.0; self.buttons[b].pressed = bool(on)
    def _loop(self):
        AX = {0: 0, 1: 1, 2: 2, 5: 3}
        while True:
            devs = glob.glob('/dev/input/by-id/*event-joystick')
            if not devs:
                self.connected = False; time.sleep(1); continue
            try:
                fd = os.open(devs[0], os.O_RDONLY); rng = {}
                for ax in AX:
                    v = struct.unpack('6i', fcntl.ioctl(fd, 0x80184540 + ax, b'\0' * 24)); rng[ax] = (v[1], v[2])
                self.connected = True
                while True:
                    if not select.select([fd], [], [], 0.5)[0]: continue
                    _, _, typ, code, val = struct.unpack('llHHi', os.read(fd, 24))
                    if typ == 3 and code in AX:
                        lo, hi = rng[code]; self.axes[AX[code]].value = 2 * (val - lo) / (hi - lo) - 1
                    elif typ == 3 and code in (16, 17):                         # Steuerkreuz (HAT0X/Y)
                        a, b = (14, 15) if code == 16 else (12, 13)
                        self._set(a, val < 0); self._set(b, val > 0)
                    elif typ == 1 and 0 <= code - 288 < 12:                     # BTN_TRIGGER.. (generisches HID)
                        self._set(code - 288, val)
            except OSError:
                self.connected = False
                for v in self.axes: v.value = 0.0
                time.sleep(1)

DETECTOR_ENGINE = os.path.expanduser('~/jetbot/ssdlite320.engine')   # gebaut von ~/jetbot/build_detector.sh

def _ssdlite(threshold):
    import torchvision
    # score_thresh/topk begrenzen die Nachverarbeitung (4 -> 8 fps)
    return torchvision.models.detection.ssdlite320_mobilenet_v3_large(
        weights='DEFAULT', score_thresh=threshold, topk_candidates=100, detections_per_img=20).eval()

def _ssd_core(m):
    """Backbone + Head von SSDlite (der rechenintensive Teil) als Modul fuer den ONNX-Export."""
    import torch
    class Core(torch.nn.Module):
        def __init__(s): super().__init__(); s.b, s.h = m.backbone, m.head
        def forward(s, x):
            h = s.h(list(s.b(x).values())); return h['bbox_regression'], h['cls_logits']
    return Core()

def export_detector_onnx(path='ssdlite320.onnx'):
    import torch, nanotrt
    return nanotrt.export(_ssd_core(_ssdlite(0.4)), torch.zeros(1, 3, 320, 320), path)

class ObjectDetector:
    """Ersatz fuer jetbot.ObjectDetector: torchvision SSDlite320-MobileNetV3 (COCO). engine_path wird ignoriert.
    Mit ~/jetbot/ssdlite320.engine (build_detector.sh) laufen Backbone und Head in TensorRT, sonst in PyTorch FP16.
    Aufruf mit BGR-Bild (oder Liste): [[{'label': COCO-ID (1 = Person), 'confidence': 0..1, 'bbox': [x0, y0, x1, y1] relativ}]]"""
    def __init__(self, engine_path=None, threshold=0.4):
        import torch
        self.torch, self.threshold = torch, threshold
        self.model = _ssdlite(threshold).cuda(); self.anchors = None
        if os.path.exists(DETECTOR_ENGINE):
            import nanotrt
            self.core = nanotrt.TRTModule(DETECTOR_ENGINE)
        else:
            core = _ssd_core(self.model).half()
            self.core = lambda x: [o.float() for o in core(x.half())]
            print('ObjectDetector: PyTorch FP16 (~12 fps). TensorRT (~17 fps): ~/jetbot/build_detector.sh')
    def _detect(self, img):
        """img: RGB float CUDA (3, H, W) 0..1. Statt der 90er-Klassenschleife von torchvision (bei 918 MHz CPU-gebunden):
        Top-k ueber alle Anker x Klassen, dann eine batched_nms."""
        import torchvision
        torch, m = self.torch, self.model
        mean = torch.tensor(m.transform.image_mean, device='cuda').view(3, 1, 1)
        std = torch.tensor(m.transform.image_std, device='cuda').view(3, 1, 1)
        x = (torch.nn.functional.interpolate(img[None], size=(320, 320), mode='bilinear', align_corners=False) - mean) / std
        bbox, cls = self.core(x)
        if self.anchors is None:                            # Anker haengen nur von den Groessen ab: einmal berechnen
            il = torchvision.models.detection.image_list.ImageList(x, [(320, 320)])
            self.anchors = m.anchor_generator(il, list(m.backbone(x.to(next(m.parameters()).dtype)).values()))[0].float()
        boxes = m.box_coder.decode_single(bbox[0], self.anchors).clamp(0, 320) / 320
        n = cls.shape[-1] - 1                               # Klasse 0 = Hintergrund
        v, i = torch.softmax(cls[0], -1)[:, 1:].flatten().topk(200)
        k = v >= self.threshold; v, i = v[k], i[k]
        a, lab = i // n, i % n + 1
        keep = torchvision.ops.batched_nms(boxes[a], v, lab, m.nms_thresh)[:20]
        return [{'label': int(l), 'confidence': float(c), 'bbox': bb}
                for l, c, bb in zip(lab[keep].tolist(), v[keep].tolist(), boxes[a][keep].tolist())]
    def __call__(self, image):
        import cv2
        torch = self.torch; imgs = image if isinstance(image, list) else [image]
        with torch.no_grad():
            return [self._detect(torch.from_numpy(cv2.cvtColor(i, cv2.COLOR_BGR2RGB)).cuda().permute(2, 0, 1).float().div_(255))
                    for i in imgs]

__all__ = ['ObjectDetector', 'Robot', 'Camera', 'Heartbeat', 'Gamepad', 'Motor', 'bgr8_to_jpeg', 'battery_v']
