"""Donkeycar-Teile fuer Jetson Nano / Ubuntu 26.04: PCA9685 per smbus2 und NanoCam (CSI IMX219)."""
import sys, time, threading
sys.path.insert(0, '/home/jetson/jetracer'); sys.path.insert(0, '/opt/nanocam')
from jetracer.nvidia_racecar import PCA9685 as _Chip, find_bus   # gleicher Treiber wie JetRacer (50 Hz, 4096 Ticks)

THROTTLE_LOCK = True   # Testmodus: Kanal 1 (Gas) immer exakt 307 Ticks = 1500 us. Fuer Fahrbetrieb auf False setzen.
_chips = {}
class PCA9685:
    """Gleiche Schnittstelle wie donkeycar.parts.actuator.PCA9685 (set_pulse in Ticks, nicht us)."""
    def __init__(self, channel, address=0x40, frequency=50, busnum=None, init_delay=0.1):
        bus = busnum if busnum is not None else find_bus()
        key = (bus, address)
        if key not in _chips: _chips[key] = _Chip(bus, address, frequency)
        self.chip, self.channel = _chips[key], channel
        time.sleep(init_delay)
    def set_pulse(self, pulse):
        if THROTTLE_LOCK and self.channel == 1: pulse = 307
        self.chip.pulse(self.channel, int(pulse) * self.chip.us_per_tick)
    def run(self, pulse): self.set_pulse(pulse)

class NanoCamPart:
    """Kamera-Teil: liefert RGB uint8 (h, w, 3). threaded=True im Vehicle."""
    def __init__(self, image_w=160, image_h=120, framerate=20):
        from nanocam import NanoCam
        self.cam, self.frame, self.on = NanoCam(image_w, image_h), None, True
        self.frame = self.cam.read()[:, :, ::-1].copy()
    def update(self):
        while self.on: self.frame = self.cam.read()[:, :, ::-1].copy()
    def run_threaded(self): return self.frame
    def run(self): return self.cam.read()[:, :, ::-1].copy()
    def shutdown(self): self.on = False; time.sleep(0.2); self.cam.close()
