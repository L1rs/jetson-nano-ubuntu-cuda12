#!/bin/bash
# Container: erzeugt den Patch aus /build/orig (Original) gegen /build/kernel-oot
cd /build && diff -ruN -x '*.o' -x '*.ko' -x '*.cmd' -x '*.mod*' -x modules.order -x Module.symvers -x '.*.d' -x out -x nvethernetrm -x '*.a' orig/nvidia-oot kernel-oot/nvidia-oot | sed -E 's#^(---|\+\+\+) (orig|kernel-oot)/#\1 \2/#' > /w/oot-6.18-t210.patch
cd /build && diff -ruN -x '*.o' -x '*.ko' -x '*.cmd' -x '*.mod*' -x modules.order -x Module.symvers -x '.*.d' -x '*.a' orig/nvgpu kernel-oot/nvgpu >> /w/oot-6.18-t210.patch
