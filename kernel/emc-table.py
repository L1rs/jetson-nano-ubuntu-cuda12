#!/usr/bin/env python3
"""L4T-4.9-EMC-Tabellen (dts aus dem live-FDT, vom Bootloader trainiert) -> Binaerformat
struct tegra210_emc_timing (drivers/memory/tegra/tegra210-emc.h, 6.18, little endian).
Aufruf: emc-table.py <l4t-live.dts> <ram-code> <out.bin>   (ohne Args: Selbsttest)
"""
import re, struct, sys

C = ['c0d0u0', 'c0d0u1', 'c0d1u0', 'c0d1u1', 'c1d0u0', 'c1d0u1', 'c1d1u0', 'c1d1u1']
# (DT-Property, Anzahl u32 bzw. '<n>s' fuer char[n]) in Struct-Reihenfolge
FIELDS = [('nvidia,revision', 1), ('nvidia,dvfs-version', '60s'), ('clock-frequency', 1),
          ('nvidia,emc-min-mv', 1), ('nvidia,gk20a-min-mv', 1), ('nvidia,source', '32s'),
          ('nvidia,src-sel-reg', 1), ('nvidia,needs-training', 1), ('nvidia,training_pattern', 1),
          ('nvidia,trained', 1), ('nvidia,periodic_training', 1)] + \
    [('nvidia,trained_dram_clktree_' + c, 1) for c in C] + \
    [('nvidia,current_dram_clktree_' + c, 1) for c in C] + \
    [('nvidia,run_clocks', 1), ('nvidia,tree_margin', 1),
     ('nvidia,burst-regs-num', 1), ('nvidia,burst-regs-per-ch-num', 1), ('nvidia,trim-regs-num', 1),
     ('nvidia,trim-regs-per-ch-num', 1), ('nvidia,burst-mc-regs-num', 1), ('nvidia,la-scale-regs-num', 1),
     ('nvidia,vref-regs-num', 1), ('nvidia,training-mod-regs-num', 1), ('nvidia,dram-timing-regs-num', 1),
     ('nvidia,ptfv', 12), ('nvidia,emc-registers', 221), ('nvidia,emc-burst-regs-per-ch', 8),
     ('nvidia,emc-shadow-regs-ca-train', 221), ('nvidia,emc-shadow-regs-quse-train', 221),
     ('nvidia,emc-shadow-regs-rdwr-train', 221), ('nvidia,emc-trim-regs', 138),
     ('nvidia,emc-trim-regs-per-ch', 10), ('nvidia,emc-vref-regs', 4), ('nvidia,emc-dram-timing-regs', 5),
     ('nvidia,emc-training-mod-regs', 20), ('nvidia,emc-save-restore-mod-regs', 12),
     ('nvidia,emc-burst-mc-regs', 33), ('nvidia,emc-la-scale-regs', 24)] + \
    [('nvidia,' + n, 1) for n in (
        'min-mrs-wait emc-mrw emc-mrw2 emc-mrw3 emc-mrw4 emc-mrw9 emc-mrs emc-emrs emc-emrs2 '
        'emc-auto-cal-config emc-auto-cal-config2 emc-auto-cal-config3 emc-auto-cal-config4 '
        'emc-auto-cal-config5 emc-auto-cal-config6 emc-auto-cal-config7 emc-auto-cal-config8 '
        'emc-cfg-2 emc-sel-dpd-ctrl emc-fdpd-ctrl-cmd-no-ramp dll-clk-src '
        'clk-out-enb-x-0-clk-enb-emc-dll emc-clock-latency-change').split()]
SIZE = 4928  # sizeof(struct tegra210_emc_timing)


def entries(dts, ram_code):
    """Nominal-Eintraege (emc-table@<rate>) des Knotens mit nvidia,ram-code = <ram_code>."""
    out, cur, in_code = [], None, False
    for line in dts.splitlines():
        s = line.strip()
        m = re.match(r'nvidia,ram-code = <(0x[0-9a-f]+)>;', s)
        if m:
            in_code, cur = int(m.group(1), 16) == ram_code, None
        elif in_code and re.match(r'emc-table@\d+ \{', s):
            cur = {}
        elif cur is not None and s == '};':
            out.append(cur); cur = None
        elif cur is not None and ' = ' in s:
            k, v = s.rstrip(';').split(' = ', 1)
            cur[k] = v[1:-1] if v.startswith('"') else [int(x, 0) for x in v.strip('<>').split()]
    return out


def pack(e):
    b = b''
    for k, n in FIELDS:
        v = e[k]
        if isinstance(n, str):
            b += struct.pack(n, v.encode())
        else:
            assert len(v) == n, (k, len(v), n)
            b += struct.pack('<%dI' % n, *v)
    assert len(b) == SIZE
    return b


def build(dts, ram_code):
    es = sorted(entries(dts, ram_code), key=lambda e: e['clock-frequency'])  # driver needs ascending rates (L4T 32.7 lists them descending)
    assert es and all(e['nvidia,trained'] == [1] for e in es), 'Tabelle fehlt oder nicht trainiert'
    return b''.join(pack(e) for e in es) + bytes(SIZE)  # Null-Eintrag beendet die Tabelle


if __name__ == '__main__':
    if len(sys.argv) == 4:
        blob = build(open(sys.argv[1]).read(), int(sys.argv[2], 0))
        open(sys.argv[3], 'wb').write(blob)
        print(len(blob) // SIZE - 1, 'Eintraege,', len(blob), 'Bytes')
    else:  # Selbsttest: Feldgroessen = Struct-Groesse, Rate an Offset 64
        fake = {k: ('x' if isinstance(n, str) else list(range(n))) for k, n in FIELDS}
        fake['clock-frequency'] = [1600000]
        b = pack(fake)
        assert struct.unpack_from('<I', b, 64)[0] == 1600000
        print('ok')
