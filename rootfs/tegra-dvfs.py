#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# tegra-dvfs: einfache Taktanpassung fuer GPU (GM20B) und Speicher (EMC) auf dem Jetson Nano unter Mainline.
# Last -> sofort volle Takte (GPU 640 MHz, EMC 1600 MHz); laenger Leerlauf -> GPU 77 MHz, EMC 204 MHz.
# Die CPU skaliert selbst (cpufreq schedutil), ihr Maximum setzt tegra-clocks.service.
# Als root (systemd: tegra-dvfs.service). Einstellbar per Umgebung: GPU_MAX, GPU_IDLE, EMC_IDLE, HOLD_S, CPU_BUSY.
# ponytail: zwei Stufen mit Hysterese statt Regelkreis; Zwischenstufen erst, wenn Messungen sie rechtfertigen.
import os, subprocess, time

GPU_MAX = int(os.environ.get('GPU_MAX', 640)); GPU_IDLE = int(os.environ.get('GPU_IDLE', 77))
EMC_MAX = 1600000000; EMC_IDLE = int(os.environ.get('EMC_IDLE', 204000000))
HOLD_S = float(os.environ.get('HOLD_S', 3))          # so lange muss alles ruhig sein, bevor runtergetaktet wird
CPU_BUSY = float(os.environ.get('CPU_BUSY', 0.30))   # Anteil eines Kerns (meistbelasteter), ab dem EMC hoch bleibt
LOAD = '/sys/devices/platform/57000000.gpu/load'     # 0..1000
RW = '/run/sysfs-rw'                                 # /sys/module ist durch tegra-fake-fuse schreibgeschuetzt
if not os.path.ismount(RW):
    os.makedirs(RW, exist_ok=True); subprocess.run(['mount', '-t', 'sysfs', 'sysfs', RW], check=True)
GPU_P = RW + '/module/nvgpu/parameters/t210_gpu_mhz'
EMC_MIN, EMC_MAXF = '/sys/kernel/debug/emc/min_rate', '/sys/kernel/debug/emc/max_rate'

def w(p, v):
    with open(p, 'w') as f: f.write(str(v))

def set_level(high):
    if high:   # erst Speicher hoch, dann GPU
        w(EMC_MAXF, EMC_MAX); w(EMC_MIN, EMC_MAX); w(GPU_P, GPU_MAX)
    else:
        w(GPU_P, GPU_IDLE); w(EMC_MIN, EMC_IDLE); w(EMC_MAXF, EMC_IDLE)

def cpu_times():
    out = []
    for l in open('/proc/stat'):
        if l.startswith('cpu') and l[3].isdigit():
            v = list(map(int, l.split()[1:])); out.append((sum(v), v[3] + v[4]))
    return out

def busiest(prev, cur):   # hoechste Auslastung eines Kerns seit der letzten Messung
    return max(((t1 - t0) - (i1 - i0)) / max(1, t1 - t0) for (t0, i0), (t1, i1) in zip(prev, cur)) if len(prev) == len(cur) else 1.0

def syncpt_irqs():
    """host1x syncpoint interrupts (rise only while the camera captures, ~60/s; idle 0).
    EMC must not switch during a capture: that hangs the VI (MW_ACK_DONE syncpt timeout)."""
    for l in open('/proc/interrupts'):
        if l.rstrip().endswith('host1x_syncpt'): return sum(int(x) for x in l.split()[1:5] if x.isdigit())
    return 0

def main():
    high = True; set_level(True); quiet = 0.0; prev = cpu_times(); irq = syncpt_irqs()
    while True:
        time.sleep(0.25); cur = cpu_times()
        try: gload = int(open(LOAD).read())
        except (OSError, ValueError): gload = 1000
        irq0, irq = irq, syncpt_irqs()
        busy = gload > 50 or busiest(prev, cur) > CPU_BUSY or irq != irq0; prev = cur
        if busy:
            quiet = 0.0
            if not high: set_level(True); high = True
        else:
            quiet += 0.25
            if high and quiet >= HOLD_S: set_level(False); high = False

def selftest():
    a, b = [(100, 50), (100, 90)], [(200, 60), (200, 190)]
    assert abs(busiest(a, b) - 0.9) < 1e-9          # Kern 0: 90 % busy
    assert busiest(a, b[:1]) == 1.0                 # Kernanzahl geaendert -> sicherheitshalber busy

if __name__ == '__main__':
    import sys
    selftest()
    if sys.argv[1:] != ['--selftest']:
        try: main()
        finally: set_level(True)                    # beim Beenden volle Takte (wie ohne Dienst)
