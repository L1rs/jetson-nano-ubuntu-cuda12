# OLED-Statusanzeige (systemd: jetbot-oled.service): IP, Akku, CPU-Last/Temperatur, RAM.
import socket, time, os, sys
sys.path.insert(0, os.path.dirname(__file__))
from jetbot_hw import Oled, battery_v, battery_pct

def ip():
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.connect(('192.0.2.1', 9)); return s.getsockname()[0]
    except OSError:
        return 'kein Netz'

o = Oled()
while True:
    v = battery_v()
    temp = int(open('/sys/class/thermal/thermal_zone0/temp').read()) // 1000
    mem = dict(l.split(':') for l in open('/proc/meminfo'))
    used = (int(mem['MemTotal'].split()[0]) - int(mem['MemAvailable'].split()[0])) // 1024
    o.text([f'wlan0: {ip()}', f'Akku: {v:.1f}V  {battery_pct(v):.0f}%',
            f'CPU: {os.getloadavg()[0]:.1f}  {temp}C', f'RAM: {used} MB'])
    time.sleep(2)
