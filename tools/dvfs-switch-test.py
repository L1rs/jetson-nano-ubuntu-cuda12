# Stresstest: GPU-/EMC-Takt waehrend GPU-Matmul (mit Ergebnispruefung) staendig umschalten. Als root.
import random, time, threading, torch
import os, subprocess
if not os.path.ismount('/run/sysfs-rw'): os.makedirs('/run/sysfs-rw', exist_ok=True); subprocess.run(['mount', '-t', 'sysfs', 'sysfs', '/run/sysfs-rw'], check=True)
P = '/run/sysfs-rw/module/nvgpu/parameters/t210_gpu_mhz'; EMC = '/sys/kernel/debug/emc/min_rate'
def w(p, v): open(p, 'w').write(str(v))
EMX = '/sys/kernel/debug/emc/max_rate'
def emc(hz):  # Reihenfolge so, dass min <= max bleibt
    if hz < 1600000000: w(EMC, hz); w(EMX, hz)
    else: w(EMX, hz); w(EMC, hz)
emc_rate = lambda: int(open('/sys/kernel/debug/clk/emc/clk_rate').read())
emc(204000000); time.sleep(0.2); print('EMC low:', emc_rate()); emc(1600000000); time.sleep(0.2); print('EMC high:', emc_rate())
a = torch.randn(1024, 1024, device='cuda'); ref = (a @ a).cpu(); bad = n = sw = 0; stop = False
def toggler():
    global sw
    while not stop:
        w(P, random.choice((77, 230, 460, 640))); emc(random.choice((204000000, 1600000000))); sw += 1; time.sleep(random.uniform(0.05, 0.5))
t = threading.Thread(target=toggler); t.start(); end = time.time() + 120
while time.time() < end:
    r = (a @ a).cpu(); n += 1
    if not torch.allclose(r, ref, rtol=1e-3, atol=1e-2): bad += 1
stop = True; t.join(); w(P, 640); emc(1600000000)
print(f'{n} Matmuls, {bad} falsch, {sw} Umschaltungen')
