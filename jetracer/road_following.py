"""Road-Following in reinem PyTorch (fp16) mit NanoCam. Aufruf: python road_following.py [--drive] [--throttle 0.0] [--secs 10]
Ohne --drive wird nur gemessen (Auto wird nicht angesteuert)."""
import sys, time, argparse, threading, torch, torchvision, numpy as np
from nanocam import NanoCam
ap = argparse.ArgumentParser()
ap.add_argument('--drive', action='store_true'); ap.add_argument('--throttle', type=float, default=0.0)
ap.add_argument('--secs', type=float, default=10); ap.add_argument('--gain', type=float, default=0.75)
ap.add_argument('--bias', type=float, default=0.0)
ap.add_argument('--model', default='/home/jetson/jetracer/notebooks/road_following_model.pth')
a = ap.parse_args()
m = torchvision.models.resnet18(weights=None); m.fc = torch.nn.Linear(512, 2)
m.load_state_dict(torch.load(a.model, map_location='cpu')); m = m.cuda().eval().half()
mean = torch.tensor([0.485, 0.456, 0.406], device='cuda').view(1, 3, 1, 1)
std = torch.tensor([0.229, 0.224, 0.225], device='cuda').view(1, 3, 1, 1)
car = None
if a.drive:
    from jetracer.nvidia_racecar import NvidiaRacecar
    car = NvidiaRacecar(); car.throttle = a.throttle
cam = NanoCam(224, 224)
n, t0, xs = 0, time.time(), []
st = {'img': None, 'seq': 0, 'run': True}
def grab():                                                # Kamera in eigenem Thread: Capture/Debayer laeuft parallel zur GPU (17 statt 12 fps)
    while st['run']: st['img'] = cam.read(); st['seq'] += 1
th = threading.Thread(target=grab, daemon=True); th.start(); last = 0
try:
    while time.time() - t0 < a.secs:
        if st['seq'] == last: time.sleep(0.001); continue
        last = st['seq']; img = st['img']                  # BGR uint8, wie jetcam im Original (Training nutzte dieselbe Reihenfolge)
        x = torch.from_numpy(np.ascontiguousarray(img)).cuda().permute(2, 0, 1)[None].float() / 255
        with torch.no_grad(): out = m(((x - mean) / std).half()).float().cpu().numpy().flatten()
        xs.append(float(out[0])); n += 1
        if car: car.steering = float(out[0]) * a.gain + a.bias
finally:
    st['run'] = False
    if car: car.throttle = 0.0; car.steering = 0.0
    print(f'{n} Frames, {n/(time.time()-t0):.1f} fps, x min/mean/max {min(xs):.2f}/{np.mean(xs):.2f}/{max(xs):.2f}')
