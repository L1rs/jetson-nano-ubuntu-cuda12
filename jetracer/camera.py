"""jetcam-kompatibler Ersatz fuer u2604: CSICamera (NanoCam), bgr8_to_jpeg, ClickableImageWidget (anywidget)."""
import sys, threading, traitlets, numpy as np
sys.path.insert(0, '/opt/nanocam')
from nanocam import NanoCam

def bgr8_to_jpeg(value, quality=75):
    import cv2
    return bytes(cv2.imencode('.jpg', value, [cv2.IMWRITE_JPEG_QUALITY, quality])[1])

class CSICamera(traitlets.HasTraits):
    value = traitlets.Any()
    width = traitlets.Integer(default_value=224)
    height = traitlets.Integer(default_value=224)
    running = traitlets.Bool(default_value=False)
    def __init__(self, width=224, height=224, capture_fps=30, **kw):   # capture_fps: NanoCam laeuft mit 30 fps
        super().__init__(width=width, height=height)
        self.cam = NanoCam(width, height)
        self.value = self.read()
        self._t = None
    def read(self):
        return np.ascontiguousarray(self.cam.read())
    def _loop(self):
        while self.running:
            self.value = self.read()
    @traitlets.observe('running')
    def _on_running(self, change):
        if change['new'] and not (self._t and self._t.is_alive()):
            self._t = threading.Thread(target=self._loop, daemon=True); self._t.start()
        elif not change['new'] and self._t:
            self._t.join(2)
    def close(self):
        self.running = False; self.cam.close()

import anywidget
class ClickableImageWidget(anywidget.AnyWidget):
    """Wie jupyter_clickable_image_widget: value = JPEG-Bytes, Klick -> on_msg({'event':'click','eventData':{offsetX,offsetY}})."""
    _esm = """
    function render({ model, el }) {
      const img = document.createElement('img'); el.appendChild(img);
      const set = () => { const v = model.get('value'); if (v && v.buffer) {
        const u = URL.createObjectURL(new Blob([v.buffer], {type: 'image/jpeg'})); img.onload = () => URL.revokeObjectURL(u); img.src = u; }
        img.width = model.get('width'); img.height = model.get('height'); };
      model.on('change:value', set); model.on('change:width', set); model.on('change:height', set); set();
      img.addEventListener('click', e => model.send({event: 'click', eventData: {offsetX: e.offsetX, offsetY: e.offsetY}}));
    }
    export default { render };
    """
    value = traitlets.Bytes(allow_none=True).tag(sync=True)
    width = traitlets.Int(224).tag(sync=True)
    height = traitlets.Int(224).tag(sync=True)
    def __init__(self, **kw):
        super().__init__(**kw)
