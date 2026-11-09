# Gamepad-Steuerung (USB-Dongle im PC-Modus, evdev, ohne Zusatzpakete). Linker Stick Y = Gas, rechter Stick X = Lenken
# (Modus mit 2 LEDs, sonst liefern die Sticks nur 0/Vollausschlag). Kennlinie --expo: feines Gas um die Mitte.
# Stopp bei Ende, Fehler oder Verbindungsverlust; danach wird auf das Gamepad gewartet.
# Optional Totmann (--deadman 0 = beliebige Taste halten). --probe zeigt nur Ereignisse (Motoren bleiben aus).
import argparse, fcntl, glob, struct, os, sys, select, time
sys.path.insert(0, os.path.dirname(__file__))

ap = argparse.ArgumentParser()
ap.add_argument('--max', type=float, default=0.5, help='Hoechstgeschwindigkeit 0..1')
ap.add_argument('--turn', type=float, default=0.6, help='Lenkanteil 0..1')
ap.add_argument('--expo', type=float, default=2.0, help='Kennlinie: 1 = linear, 2 = quadratisch (feiner um die Mitte)')
ap.add_argument('--deadman', type=int, default=-1, help='Tastencode (siehe --probe), 0 = beliebige Taste, -1 = aus')
ap.add_argument('--steer', type=int, default=2, help='Achse fuers Lenken (2 = rechter Stick X, 0 = linker Stick X)')
ap.add_argument('--probe', action='store_true')
a = ap.parse_args()
m = None if a.probe else __import__('jetbot_hw').Motors()

def curve(t):
    t = 0.0 if abs(t) < 0.08 else t                  # Totzone gegen Drift
    return (abs(t) ** a.expo) * (1 if t > 0 else -1)

LOCK = '/dev/shm/jetbot-notebook'                    # gesetzt von jetbot.Robot() in Notebooks
def notebook_active():
    try: return os.path.exists('/proc/' + open(LOCK).read().strip())
    except OSError: return False

def run(dev):
    fd = os.open(dev, os.O_RDONLY); rng = {}
    for ax in (0, 1, 2, 5):                          # EVIOCGABS: value,min,max,fuzz,flat,res
        try:
            v = struct.unpack('6i', fcntl.ioctl(fd, 0x80184540 + ax, b'\0' * 24)); rng[ax] = (v[1], v[2])
        except OSError:
            pass
    print(dev, 'Achsen', rng, flush=True)
    norm = lambda ax, v: (2 * (v - rng[ax][0]) / (rng[ax][1] - rng[ax][0]) - 1) if ax in rng else 0.0
    x = y = 0.0; down = set()
    try:
        while True:
            if not select.select([fd], [], [], 0.5)[0]:
                continue
            _, _, typ, code, val = struct.unpack('llHHi', os.read(fd, 24))
            if a.probe:
                if typ in (1, 3): print('Taste' if typ == 1 else 'Achse', code, val, flush=True)
                continue
            if typ == 3 and code == a.steer: x = curve(norm(a.steer, val)) * a.turn
            elif typ == 3 and code == 1: y = -curve(norm(1, val))
            elif typ == 1: (down.add if val else down.discard)(code)
            else: continue
            l, r = y + x, y - x
            held = a.deadman < 0 or (down if a.deadman == 0 else a.deadman in down)
            k = a.max / max(1.0, abs(l), abs(r)) if held else 0.0
            if notebook_active(): continue           # Notebook steuert die Motoren
            m.set(l * k, r * k)
    finally:
        if m: m.stop()
        os.close(fd)

while True:                                          # Gamepad weg (Moduswechsel, Akku leer) -> stoppen und warten
    devs = glob.glob('/dev/input/by-id/*event-joystick')
    try:
        if devs: run(devs[0])
    except OSError as e:
        print('Gamepad getrennt:', e, flush=True)
    except KeyboardInterrupt:
        break
    time.sleep(1)
