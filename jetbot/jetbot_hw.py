# Waveshare JetBot-Board (Ubuntu 26.04 / Mainline): Motoren (PCA9685 0x60 -> TB6612), Akku (ADS1115 0x48), OLED (SSD1306 128x32, 0x3c).
# Nur smbus2 + PIL. Kanalbelegung wie waveshare/jetbot motor.py: links IN 1/0, rechts IN 2/3.
import atexit, glob, os, sys, time
from smbus2 import SMBus, i2c_msg

def i2c_bus():  # Bus an Pins 3/5 (7000c400.i2c), Nummer haengt von der Probe-Reihenfolge ab
    for d in glob.glob('/sys/bus/i2c/devices/i2c-*'):
        if '7000c400.i2c' in os.readlink(d):
            return int(d.rsplit('-', 1)[1])
    raise RuntimeError('I2C-Bus 7000c400 nicht gefunden')

BUS = SMBus(i2c_bus())

class Motors:
    # Wie waveshare/jetbot motor.py (Adafruit MotorHAT + eigene IN-Kanaele): PWM-Kanal, IN1/IN2 (Adafruit), ina/inb (Waveshare)
    CH = {'left': (8, 10, 9, 1, 0), 'right': (13, 11, 12, 2, 3)}
    def __init__(self, addr=0x60, freq=1600, alpha=(1.0, 1.0)):
        self.a, self.alpha = addr, alpha             # alpha: Abgleich links/rechts, falls der Bot nicht geradeaus faehrt
        BUS.write_byte_data(addr, 0x00, 0x10)                          # sleep
        BUS.write_byte_data(addr, 0xFE, int(round(25e6 / (4096 * freq)) - 1))
        BUS.write_byte_data(addr, 0x00, 0x20); time.sleep(0.005)       # wake, auto-increment
        BUS.write_byte_data(addr, 0x00, 0xA0)
        self.stop(); atexit.register(self.stop)
    def _pwm(self, ch, duty):                        # duty 0..4095, 4096 = dauerhaft an
        on = 0x1000 if duty >= 4096 else 0; off = 0 if on else duty
        BUS.write_i2c_block_data(self.a, 0x06 + 4 * ch, [on & 0xFF, on >> 8, off & 0xFF, off >> 8])
    def _one(self, side, v, k):
        v = max(-1.0, min(1.0, v * k)); pwm, in1, in2, ina, inb = self.CH[side]; d = int(abs(v) * 4095)
        self._pwm(pwm, d)
        self._pwm(in1, 0 if v > 0 else (4096 if v < 0 else 0)); self._pwm(in2, 4096 if v > 0 else 0)
        self._pwm(ina, d if v > 0 else 0); self._pwm(inb, d if v < 0 else 0)
    def set(self, left, right):                      # -1..1
        self._one('left', left, self.alpha[0]); self._one('right', right, self.alpha[1])
    def stop(self):
        self.set(0, 0)

def battery_v(addr=0x48):                            # ADS1115 AIN0 gegen GND, +-4.096 V, Teiler 1:4 (Waveshare)
    BUS.write_i2c_block_data(addr, 0x01, [0xC3, 0x83])                 # Single-Shot AIN0, PGA 4.096, 128 SPS
    time.sleep(0.01)
    hi, lo = BUS.read_i2c_block_data(addr, 0x00, 2); raw = (hi << 8 | lo)
    raw -= 65536 if raw > 32767 else 0
    return raw * 0.000125 * 4

def battery_pct(v):                                  # 3S Li-Ion, grob linear 9.6..12.6 V
    return max(0, min(100, (v - 9.6) / 3.0 * 100))

class Oled:
    def __init__(self, addr=0x3c, w=128, h=32):
        self.a, self.w, self.h = addr, w, h
        for c in (0xAE, 0xD5, 0x80, 0xA8, h - 1, 0xD3, 0, 0x40, 0x8D, 0x14, 0x20, 0, 0xA1, 0xC8,
                  0xDA, 0x02, 0x81, 0x8F, 0xD9, 0xF1, 0xDB, 0x40, 0xA4, 0xA6, 0xAF):
            BUS.write_byte_data(addr, 0x00, c)
    def show(self, img):                             # PIL-Bild Modus '1', w x h
        px = img.load(); buf = bytearray()
        for p in range(self.h // 8):
            for x in range(self.w):
                buf.append(sum(1 << b for b in range(8) if px[x, p * 8 + b]))
        for c in (0x21, 0, self.w - 1, 0x22, 0, self.h // 8 - 1):
            BUS.write_byte_data(self.a, 0x00, c)
        for i in range(0, len(buf), 32):
            BUS.write_i2c_block_data(self.a, 0x40, list(buf[i:i + 32]))
    def text(self, lines, font=os.environ.get('OLED_FONT', ''), size=8):
        from PIL import Image, ImageDraw, ImageFont
        img = Image.new('1', (self.w, self.h)); d = ImageDraw.Draw(img); d.fontmode = '1'   # ohne Kantenglaettung
        # leer = kleine Pixelschrift wie bei Waveshare (Pillow >=10 nimmt sonst eine groessere), sonst Pfad einer TTF
        f = ImageFont.truetype(font, size) if font else ImageFont.load_default_imagefont()
        for y, t in zip((-2, 6, 14, 23) if not font else (0, 8, 16, 24), lines[:4]):  # Zeilen wie waveshare/jetbot stats.py
            d.text((0, y), t, font=f, fill=255)
        self.show(img)

if __name__ == '__main__':                           # Selbsttest ohne Bewegung
    v = battery_v(); print(f'Akku {v:.2f} V ({battery_pct(v):.0f} %)')
    assert 5 < v < 13.5, 'Akkuspannung unplausibel'
    Oled().text(['JetBot Selbsttest', f'Akku {v:.1f} V', 'Motoren: Stopp'])
    m = Motors(); m.stop(); print('PCA9685 ok, Motoren gestoppt')
    if sys.argv[1:] == ['motortest']:                # nur aufgebockt! je 1 s: links vor, rechts vor, beide zurueck
        for name, l, r in (('links vor', .3, 0), ('rechts vor', 0, .3), ('beide zurueck', -.3, -.3)):
            print(name); m.set(l, r); time.sleep(1); m.stop(); time.sleep(0.5)
