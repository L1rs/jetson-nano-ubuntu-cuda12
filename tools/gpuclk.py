# Misst den echten SM-Takt: Kernel zaehlt %clock64-Zyklen, Vergleich mit der Wanduhr. Laeuft mit L4T-torch und u2604-torch.
import ctypes, time, torch
PTX = b"""
.version 6.0
.target sm_53
.address_size 64
.visible .entry spin(.param .u64 out, .param .u64 n) {
 .reg .u64 %r<6>; .reg .pred %p;
 ld.param.u64 %r1, [out]; ld.param.u64 %r2, [n];
 mov.u64 %r3, %clock64;
L: mov.u64 %r4, %clock64; sub.u64 %r5, %r4, %r3; setp.lt.u64 %p, %r5, %r2; @%p bra L;
 cvta.to.global.u64 %r1, %r1; st.global.u64 [%r1], %r5; ret; }
"""
cu = ctypes.CDLL('libcuda.so.1')
out = torch.zeros(1, dtype=torch.int64, device='cuda'); torch.cuda.synchronize()
mod, fn = ctypes.c_void_p(), ctypes.c_void_p()
assert cu.cuModuleLoadData(ctypes.byref(mod), PTX) == 0
assert cu.cuModuleGetFunction(ctypes.byref(fn), mod, b'spin') == 0
for n in (100_000_000, 1_000_000_000):
    p_out, p_n = ctypes.c_uint64(out.data_ptr()), ctypes.c_uint64(n)
    args = (ctypes.c_void_p * 2)(ctypes.cast(ctypes.byref(p_out), ctypes.c_void_p), ctypes.cast(ctypes.byref(p_n), ctypes.c_void_p))
    t = time.time()
    assert cu.cuLaunchKernel(fn, 1, 1, 1, 1, 1, 1, 0, None, args, None) == 0
    assert cu.cuCtxSynchronize() == 0
    dt = time.time() - t
    print('cycles %d in %.3f s -> SM clock %.1f MHz' % (out.item(), dt, out.item() / dt / 1e6))
