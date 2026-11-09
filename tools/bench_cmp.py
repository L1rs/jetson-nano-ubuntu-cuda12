# Gleicher PyTorch-Benchmark fuer L4T (Python 3.8, altes torchvision) und Ubuntu 26.04
import torch, torchvision, time
def t(f, n):
    for _ in range(5): f()
    torch.cuda.synchronize(); s = time.time()
    for _ in range(n): f()
    torch.cuda.synchronize(); return (time.time() - s) / n
print('torch', torch.__version__, 'cuda', torch.version.cuda, 'cudnn', torch.backends.cudnn.is_available() and torch.backends.cudnn.version())
for dt in (torch.float16, torch.float32):
    a = torch.randn(2048, 2048, device='cuda', dtype=dt)
    print('matmul %s: %.0f GFLOPS' % (dt, 2 * 2048**3 / t(lambda: a @ a, 30) / 1e9))
for name in ('resnet18', 'resnet50'):
    for dt in (torch.float16, torch.float32):
        m = getattr(torchvision.models, name)().eval().cuda().to(dt); x = torch.randn(1, 3, 224, 224, device='cuda', dtype=dt)
        for cd in ([False, True] if torch.backends.cudnn.is_available() else [False]):
            torch.backends.cudnn.enabled = cd; torch.backends.cudnn.benchmark = cd
            with torch.no_grad(): print('%s %s cudnn=%s: %.1f fps' % (name, dt, cd, 1 / t(lambda: m(x), 30)))
