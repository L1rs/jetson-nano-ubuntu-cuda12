#!/bin/sh
# Vergleichslauf (als root). Takte wie unter Ubuntu 26.04: CPU <= 918 MHz, GPU 640 MHz, EMC 1600 MHz.
cd "$(dirname "$0")"
for f in /sys/devices/system/cpu/cpu[0-3]/cpufreq/scaling_max_freq; do echo 918000 > $f; done
G=/sys/class/devfreq/57000000.gpu; [ -d $G ] || G=   # nur L4T (Stufen: 614.4 / 691.2 MHz, kein 640)
if [ -n "$G" ]; then echo 614400000 > $G/min_freq; echo 614400000 > $G/max_freq; echo 614400000 > $G/min_freq; fi    # L4T
[ -n "$G" ] || [ -e /run/sysfs-rw ] || { echo "GPU clock not capped, abort"; exit 1; }
if [ -d /sys/kernel/debug/clk/override.emc ]; then echo 1600000000 > /sys/kernel/debug/clk/override.emc/clk_update_rate; echo 1 > /sys/kernel/debug/clk/override.emc/clk_state; fi
echo "== $(uname -r) $(date)"; cat $G/cur_freq 2>/dev/null; cat /sys/kernel/debug/clk/emc/clk_rate 2>/dev/null
T=${TRTEXEC:-/usr/src/tensorrt/bin/trtexec}
./bandwidthTest | grep -E "^ +[0-9]"
./matrixMulCUBLAS | grep Performance
for e in r18 r50 ssdlite320; do echo "trt $e $($T --loadEngine=$e.engine --duration=10 2>&1 | grep -oE 'Throughput: [0-9.]+ qps')"; done
${PYBIN:-python3} bench_cmp.py 2>&1 | grep -v Warn
