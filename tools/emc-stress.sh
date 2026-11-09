#!/bin/sh
# 10 min: memtester 1000M (CPU0) + 2 Spinner + bandwidthTest-Schleife (GPU)
end=$(($(date +%s)+${DUR:-600}))
sudo dmesg -n 8
( sudo timeout ${DUR:-600} memtester 1000M 100 ) > /tmp/mt.log 2>&1 &
for i in 1 2; do timeout ${DUR:-600} sh -c "while :; do :; done" & done
n=0; f=0; while [ $(date +%s) -lt $end ]; do ~/bandwidthTest >/tmp/bw.out 2>&1 && n=$((n+1)) || f=$((f+1)); done
wait; echo "bw pass=$n fail=$f"; grep -E "[0-9]+\.[0-9]+$" /tmp/bw.out | tr -s "\t " " " | tr "\n" " "; echo
echo "memtester FAIL: $(tr "\b" "\n" < /tmp/mt.log | grep -c FAIL) loops: $(grep -c "^Loop" /tmp/mt.log)"
sudo cat /sys/kernel/debug/clk/emc/clk_rate; dmesg | grep -ci "error\|fault\|serror"; uptime
