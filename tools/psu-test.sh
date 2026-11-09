#!/bin/sh
# Stromtest: je Stufe CPU_KHZ, 4 Kerne CPU-Last + GPU-Matmul, DUR s. Herzschlag in ~/psu.log (überlebt Absturz).
DUR=${DUR:-300}
cat > ~/gpuload.py <<'E'
import torch,time,sys
a=torch.randn(2048,2048,device='cuda',dtype=torch.half); end=time.time()+float(sys.argv[1])
while time.time()<end: a@a; torch.cuda.synchronize()
E
for khz in $*; do
  for f in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_max_freq; do sudo sh -c "echo $khz > $f"; done
  echo "== $khz $(date +%T)" >> ~/psu.log; sync
  for i in 1 2 3; do timeout $DUR sh -c "while :; do :; done" & done
  ~/torch-venv/bin/python ~/gpuload.py $DUR >>~/gpu.err 2>&1 &
  end=$(($(date +%s)+DUR)); while [ $(date +%s) -lt $end ]; do
    echo "$(date +%T) cpu=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq) t=$(cat /sys/class/thermal/thermal_zone*/temp | tr '\n' ' ')" >> ~/psu.log; sync; sleep 5; done
  wait; echo "ok $khz" >> ~/psu.log; sync
done
for f in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_max_freq; do sudo sh -c "echo 918000 > $f"; done
echo DONE >> ~/psu.log
