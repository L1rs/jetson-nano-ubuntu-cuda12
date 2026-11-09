#!/usr/bin/env python3
"""nanocam: IMX219 am Jetson Nano unter Mainline (tegra-video, /dev/video0) als BGR-numpy-Bilder.

    from nanocam import NanoCam
    cam = NanoCam(224, 224)          # oder NanoCam(640, 480)
    frame = cam.read()               # BGR uint8, immer das neueste Bild
    cam.close()

Rohbild 1640x1232 RGGB8 (volles Sichtfeld, 2x2-Binning) per read()-I/O in einem Thread.
Debayer als 2x2-Quad (R, (G1+G2)/2, B) auf 820x616, Resize auf die Zielgroesse, dann linear:
Schwarzwert, Linsenschatten (LSC) und Farbmatrix (CCM) aus der Waveshare-ISP-Datei,
Grauwelt-AWB, sRGB-Gamma. Auto-Belichtung ueber die V4L2-Controls exposure/analogue_gain.
CLI: python3 nanocam.py [--size 224x224] [--frames 200] [--out /tmp/nanocam.jpg] [--flip]
"""
import fcntl, os, re, struct, subprocess, threading, time
import numpy as np
import cv2

VIDIOC_S_CTRL = 0xC008561C
CID_EXPOSURE, CID_VBLANK, CID_AGAIN = 0x00980911, 0x009E0901, 0x009E0903
W, H, HTS, PIXEL_RATE = 1640, 1232, 1640 + 1920, 364_800_000   # Modus 1640x1232, hblank 1920
BLACK = 16                                                       # Schwarzwert 64/1023 als 8 Bit
# Lage von R und B im 2x2-Quad je Bayer-Fourcc (aendert sich mit hflip/vflip)
BAYER = {"RGGB": ((0, 0), (1, 1)), "BGGR": ((1, 1), (0, 0)), "GRBG": ((0, 1), (1, 0)), "GBRG": ((1, 0), (0, 1))}
ISP_FILES = [os.path.join(os.path.dirname(os.path.abspath(__file__)), "camera_overrides.isp"),
             "/media/l4t/var/nvidia/nvcam/settings/camera_overrides.isp"]
GAMMA = np.array([255 * (12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055)
                  for x in np.arange(256) / 255], np.float32).clip(0, 255).astype(np.uint8)


def quad_bgr(raw, rpos, bpos):
    """Bayer (HxW, uint8) -> BGR in halber Aufloesung: je 2x2-Quad ein Pixel, G gemittelt."""
    q = raw.reshape(raw.shape[0] // 2, 2, raw.shape[1] // 2, 2)
    (ry, rx), (by, bx) = rpos, bpos
    out = np.empty((q.shape[0], q.shape[2], 3), np.uint8)
    out[..., 2] = q[:, ry, :, rx]
    out[..., 0] = q[:, by, :, bx]
    out[..., 1] = (q[:, ry, :, 1 - rx].astype(np.uint16) + q[:, by, :, 1 - bx]) >> 1
    return out


def bezier_weights(n, f=(0.25, 0.5, 0.25)):
    """n x 10 Gewichte: 3 kubische Bezier-Patches (Breiten f) entlang einer Achse, wie NVIDIA-LSC."""
    edges = np.cumsum((0.0,) + f)
    w = np.zeros((n, 10), np.float32)
    for i, u in enumerate((np.arange(n) + 0.5) / n):
        p = min(int(np.searchsorted(edges, u, "right")) - 1, 2)
        t = (u - edges[p]) / f[p]
        w[i, 3 * p:3 * p + 4] = [(1 - t) ** 3, 3 * t * (1 - t) ** 2, 3 * t * t * (1 - t), t ** 3]
    return w


def load_isp(path, size, cct=1):
    """LSC-Gainkarte (h x w x 3, BGR) und CCM (3x3, BGR) aus einer NVIDIA-.isp-Datei.
    ponytail: nur die 4000-K-Flaeche (cct=1), keine Interpolation nach Farbtemperatur."""
    txt = open(path).read()
    wy, wx = bezier_weights(size[1]), bezier_weights(size[0])

    def surf(ch):
        c = np.zeros((10, 10), np.float32)
        for i, j, v in re.findall(r"ctrlPoints\[%d\]\.controlPoint%s\[(\d)\]\[(\d)\]\s*=\s*([-\d.]+)" % (cct, ch), txt):
            c[int(i), int(j)] = float(v)
        return wy @ c @ wx.T
    lsc = np.dstack([surf("B"), (surf("GR") + surf("GB")) / 2, surf("R")])
    rows = re.findall(r"srgbMatrix\[\d\]\s*=\s*\{([^}]*)\}", txt)
    m = np.array([[float(x) for x in r.split(",")] for r in rows], np.float32).T   # Datei: Spalten = Ausgang RGB
    return lsc, m[::-1, ::-1].copy()                                             # RGB -> BGR


class NanoCam:
    def __init__(self, width=224, height=224, fps=30, dev="/dev/video0", flip=False,
                 target=45, max_exposure_ms=20.0, awb=True, isp=None):
        self.size, self.target, self.awb, self.dev = (width, height), target, awb, dev
        v4l2 = ["v4l2-ctl", "-d", dev]
        # Flip aendert das Bayer-Muster, daher vor dem Format setzen und das Fourcc zuruecklesen
        subprocess.run(v4l2 + ["-c", "horizontal_flip=%d,vertical_flip=%d" % (flip, flip)], check=True)
        out = subprocess.run(v4l2 + ["--list-formats"], check=True, capture_output=True, text=True).stdout
        bayer = next(b for b in BAYER if "'%s'" % b in out)
        subprocess.run(v4l2 + ["--set-fmt-video=width=%d,height=%d,pixelformat=%s" % (W, H, bayer)], check=True)
        out = subprocess.run(v4l2 + ["--get-fmt-video"], check=True, capture_output=True, text=True).stdout
        self.bpl = int(out.split("Bytes per Line")[1].split(":")[1].split()[0])
        self.rpos, self.bpos = BAYER[bayer]
        self.fd = os.open(dev, os.O_RDWR)
        vts = int(PIXEL_RATE / (HTS * fps))
        self._ctrl(CID_VBLANK, vts - H)
        self.exp_max = min(vts - 4, int(max_exposure_ms / 1000 * PIXEL_RATE / HTS))
        self.exp, self.gain = min(1600, self.exp_max), 1.0
        self._set_exposure()
        isp = isp or next((p for p in ISP_FILES if os.path.exists(p)), None)
        if isp:
            self.lsc, self.ccm = load_isp(isp, self.size)
            if flip:
                self.lsc = self.lsc[::-1, ::-1].copy()
        else:
            self.lsc, self.ccm = np.ones((height, width, 3), np.float32), np.eye(3, dtype=np.float32)
        self.gains = np.ones(3, np.float32)                # AWB, B G R
        self.raw, self.seq, self.last, self.n = None, 0, 0, 0
        self.new = threading.Condition()
        self.running = True
        self.t = threading.Thread(target=self._grab, daemon=True)
        self.t.start()

    def _ctrl(self, cid, val):
        fcntl.ioctl(self.fd, VIDIOC_S_CTRL, struct.pack("Ii", cid, int(val)))

    def _set_exposure(self):
        self._ctrl(CID_EXPOSURE, self.exp)
        self._ctrl(CID_AGAIN, round(256 - 256 / self.gain))   # IMX219: Gain = 256/(256-x), x <= 232

    def _grab(self):
        # liest fortlaufend (vb2 read()-Emulation), read() bekommt so immer das neueste Bild
        f = open(self.fd, "rb", buffering=0, closefd=False)
        while self.running:
            buf = bytearray(self.bpl * H)
            if f.readinto(buf) != len(buf):
                continue
            with self.new:
                self.raw, self.seq = buf, self.seq + 1
                self.new.notify_all()

    def read(self, timeout=1.0):
        with self.new:
            if not self.new.wait_for(lambda: self.seq != self.last or not self.running, timeout):
                raise TimeoutError("kein Bild von " + self.dev)
            raw, self.last = self.raw, self.seq
        half = quad_bgr(np.frombuffer(raw, np.uint8).reshape(H, self.bpl)[:, :W], self.rpos, self.bpos)
        img = cv2.resize(half, self.size, interpolation=cv2.INTER_AREA)
        lin = cv2.multiply(img.astype(np.float32) - BLACK, self.lsc)   # linear, ~0..239
        self.n += 1
        if self.n % 3 == 0:
            self._update(lin)
        m = self.ccm @ np.diag(self.gains) * (255.0 / (255 - BLACK))
        out = cv2.transform(lin, m)
        return cv2.LUT(np.clip(out, 0, 255).astype(np.uint8), GAMMA)

    def _update(self, lin):
        b, g, r = (max(c, 0.5) for c in cv2.mean(lin)[:3])
        if self.awb:   # Grauwelt, geglaettet
            want = np.clip(np.array([g / b, 1.0, g / r], np.float32), 0.25, 4.0)
            self.gains = 0.8 * self.gains + 0.2 * want
        # ponytail: P-Regler auf mittleres lineares Gruen, kein Histogramm/Spitzlichtschutz
        ratio = float(np.clip(self.target / g, 0.5, 2.0)) ** 0.6
        e = self.exp * self.gain * ratio
        exp = int(np.clip(e, 4, self.exp_max))
        gain = float(np.clip(e / exp, 1.0, 256 / 24))
        if abs(exp - self.exp) > 2 or abs(gain - self.gain) > 0.02:
            self.exp, self.gain = exp, gain
            self._set_exposure()

    def close(self):
        self.running = False
        self.t.join(timeout=2)
        os.close(self.fd)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


def _selftest():
    raw = np.zeros((4, 6), np.uint8)
    raw[0::2, 0::2], raw[0::2, 1::2], raw[1::2, 0::2], raw[1::2, 1::2] = 200, 100, 50, 10   # R G1 G2 B
    assert (quad_bgr(raw, *BAYER["RGGB"]) == [10, 75, 200]).all()
    assert (quad_bgr(raw, *BAYER["BGGR"]) == [200, 75, 10]).all()
    w = bezier_weights(64)
    assert np.allclose(w.sum(1), 1) and w[0, 0] > 0.9 and w[-1, 9] > 0.9


if __name__ == "__main__":
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument("--size", default="224x224")
    p.add_argument("--frames", type=int, default=200)
    p.add_argument("--out", default="/tmp/nanocam.jpg")
    p.add_argument("--flip", action="store_true")
    a = p.parse_args()
    _selftest()
    w, h = map(int, a.size.split("x"))
    with NanoCam(w, h, flip=a.flip) as cam:
        for _ in range(60):                       # AE/AWB einschwingen lassen
            cam.read()
        t = time.time()
        for _ in range(a.frames):
            img = cam.read()
        dt = time.time() - t
        cv2.imwrite(a.out, img)
        print("%dx%d  %.1f fps  exposure=%d gain=%.2f wb(B,G,R)=%s -> %s" % (
            w, h, a.frames / dt, cam.exp, cam.gain, np.round(cam.gains, 2), a.out))
