# Vergleichs-Benchmark: Matmul, resnet18 (fp16/fp32, cuDNN aus/an/benchmark), CPU. Ausgabe kompakt.
import torch, torchvision, time, numpy as np
def t(f, n):
    for _ in range(3): f()
    torch.cuda.synchronize(); s = time.time()
    for _ in range(n): f()
    torch.cuda.synchronize(); return (time.time() - s) / n
print('torch', torch.__version__, 'cudnn', torch.backends.cudnn.is_available())
for dt in (torch.half, torch.float):
    a = torch.randn(2048, 2048, device='cuda', dtype=dt)
    print(f'matmul {dt}: {2*2048**3/t(lambda: a@a, 30)/1e9:.0f} GFLOPS')
modes = [('ohne', False, False)] + ([('cudnn', True, False), ('cudnn+bench', True, True)] if torch.backends.cudnn.is_available() else [])
for name, en, bm in modes:
    torch.backends.cudnn.enabled, torch.backends.cudnn.benchmark = en, bm
    for dt in (torch.half, torch.float):
        m = torchvision.models.resnet18().cuda().eval().to(dt); x = torch.rand(1, 3, 224, 224, device='cuda', dtype=dt)
        with torch.no_grad(): print(f'resnet18 {name} {dt}: {1/t(lambda: m(x), 50):.1f} fps')
a = np.random.rand(1024, 1024).astype(np.float32); s = time.time()
for _ in range(10): a @ a
print(f'numpy cpu matmul: {10*2*1024**3/(time.time()-s)/1e9:.1f} GFLOPS')
