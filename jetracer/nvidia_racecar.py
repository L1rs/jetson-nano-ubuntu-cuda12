"""NvidiaRacecar fuer u2604 (Mainline): PCA9685 direkt per smbus2 statt Blinka/ServoKit. Gleiche API wie das Original."""
import glob, time, traitlets, smbus2
from .racecar import Racecar

def find_bus(name='7000c400.i2c', default=1):
    # Busnummern wechseln je nach DT; ueber den Controller-Namen suchen (Pins 3/5 = i2c@7000c400)
    for p in glob.glob('/sys/class/i2c-dev/i2c-*/name'):
        if open(p).read().strip() == name:
            return int(p.split('/')[-2].split('-')[1])
    return default

class PCA9685:
    def __init__(self, bus, addr=0x40, freq=50):
        self.b, self.a = smbus2.SMBus(bus), addr
        self.b.write_byte_data(addr, 0x00, 0x10)           # sleep
        self.b.write_byte_data(addr, 0xFE, int(round(25e6 / (4096 * freq)) - 1))
        self.b.write_byte_data(addr, 0x00, 0x20)           # wake, auto-increment
        time.sleep(0.01); self.b.write_byte_data(addr, 0x00, 0xA0)
        self.us_per_tick = 1e6 / freq / 4096
    def pulse(self, ch, us):                               # Pulsbreite in us
        off = int(us / self.us_per_tick)
        self.b.write_i2c_block_data(self.a, 0x06 + 4 * ch, [0, 0, off & 0xFF, off >> 8])

class NvidiaRacecar(Racecar):
    i2c_address = traitlets.Integer(default_value=0x40)
    i2c_bus = traitlets.Integer(default_value=-1)
    steering_gain = traitlets.Float(default_value=-0.65)
    steering_offset = traitlets.Float(default_value=0)
    steering_channel = traitlets.Integer(default_value=0)
    throttle_gain = traitlets.Float(default_value=0.8)
    throttle_channel = traitlets.Integer(default_value=1)
    # ServoKit continuous_servo: 750..2250 us, Mitte 1500 us
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.pwm = PCA9685(self.i2c_bus if self.i2c_bus >= 0 else find_bus(), self.i2c_address)
        self._set(self.steering_channel, 0.0); self._set(self.throttle_channel, 0.0)
    def _set(self, ch, v):
        self.pwm.pulse(ch, 1500 + 750 * max(-1.0, min(1.0, v)))
    @traitlets.observe('steering')
    def _on_steering(self, change):
        self._set(self.steering_channel, change['new'] * self.steering_gain + self.steering_offset)
    @traitlets.observe('throttle')
    def _on_throttle(self, change):
        self._set(self.throttle_channel, change['new'] * self.throttle_gain)
