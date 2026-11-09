import json, shutil, os
os.chdir('/home/jetson/jetracer/notebooks')
def load(n): return json.load(open(n))
def src(c, s): c['source'] = s.splitlines(True); c['outputs'] = []
def md(t): return {"cell_type":"markdown","metadata":{},"source":[t]}
def fix(s):
    return (s.replace('from jetcam.csi_camera import CSICamera','from jetracer.camera import CSICamera')
             .replace('from jetcam.utils import bgr8_to_jpeg','from jetracer.camera import bgr8_to_jpeg')
             .replace('from jupyter_clickable_image_widget import ClickableImageWidget','from jetracer.camera import ClickableImageWidget')
             .replace(', capture_fps=65','')
             .replace('pretrained=True','weights=torchvision.models.ResNet18_Weights.DEFAULT')
             .replace('pretrained=False','weights=None')
             .replace('except e:','except Exception as e:')
             .replace("torch.load(model_path_widget.value)","torch.load(model_path_widget.value, map_location='cpu')")
             .replace("torch.load('road_following_model.pth')","torch.load('road_following_model.pth', map_location='cpu')"))
NOTE = "**Portiert auf Ubuntu 26.04:** jetcam -> `jetracer.camera` (NanoCam), torch2trt/TensorRT entfaellt (reines PyTorch FP16). Original: `{}.orig.ipynb`."
for n in ['basic_motion','interactive_regression','road_following','road_following_live','optimize_model','reset_camera_service']:
    f = n + '.ipynb'; o = n + '.orig.ipynb'
    if not os.path.exists(o): shutil.copy(f, o)
    nb = load(o); cs = nb['cells']
    for c in cs:
        if c['cell_type']=='code': src(c, fix(''.join(c['source'])))
    code = [c for c in cs if c['cell_type']=='code']
    if n == 'road_following':
        src(code[2], "# TensorRT entfaellt: das FP16-PyTorch-Modell wird direkt benutzt\nmodel_trt = model")
        for c in code[3:5]: src(c, "")
    if n == 'road_following_live':
        src(code[0], "import torch, torchvision\nmodel_trt = torchvision.models.resnet18(weights=None)\nmodel_trt.fc = torch.nn.Linear(512, 2)\nmodel_trt.load_state_dict(torch.load('road_following_model.pth', map_location='cpu'))\nmodel_trt = model_trt.cuda().eval().half()")
    if n == 'optimize_model':
        for c in code: src(c, "")
        cs.insert(0, md("**Obsolet unter Ubuntu 26.04:** keine TensorRT-Optimierung noetig, `road_following.ipynb` laedt das FP16-Modell direkt."))
    elif n == 'reset_camera_service':
        for c in code: src(c, "")
        cs.insert(0, md("**Obsolet unter Ubuntu 26.04:** kein nvargus-daemon, die Kamera laeuft ueber V4L2 (NanoCam)."))
    else:
        cs.insert(0, md(NOTE.format(n)))
    json.dump(nb, open(f,'w'), indent=1)
print('ok')
