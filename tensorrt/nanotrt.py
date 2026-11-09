# SPDX-License-Identifier: MIT
"""TensorRT 8.0 engines from PyTorch on the Jetson Nano under Ubuntu 26.04 (see docs/tensorrt.md).

    import nanotrt
    nanotrt.export(model, torch.zeros(1, 3, 224, 224), 'model.onnx')   # torch -> ONNX that TensorRT 8.0 parses
    # shell:  sudo nano-trt build model.onnx model.engine                 # FP16 engine, takes 2-5 min
    m = nanotrt.TRTModule('model.engine')    # like the torch model: tensors in, CUDA tensors out
    y = m(x)

TensorRT runs in the same CUDA context as PyTorch (CUDA 10.2 runtime next to PyTorch's 12.6 runtime, one driver).
"""
import ctypes, os
import torch

_DT = {0: torch.float32, 1: torch.float16, 2: torch.int8, 3: torch.int32, 4: torch.bool}
_lib = None


def _shim():
    global _lib
    if _lib is None:
        # DEEPBIND: TensorRT must use its own cuBLAS 10 / CUDA 10.2 runtime, not PyTorch's same-named symbols.
        # TensorRT and cuDNN dlopen() these by name at run time, so they are loaded here first (dependency order).
        for n in ('libcudart.so.10.2', 'libcublasLt.so.10', 'libcublas.so.10', 'libcudnn_ops_infer.so.8',
                  'libcudnn_cnn_infer.so.8', 'libcudnn_adv_infer.so.8', 'libcudnn_ops_train.so.8',
                  'libcudnn_cnn_train.so.8', 'libcudnn_adv_train.so.8', 'libcudnn.so.8'):
            ctypes.CDLL('/opt/nanotrt/lib/' + n, mode=os.RTLD_LOCAL | os.RTLD_DEEPBIND)
        _lib = ctypes.CDLL('/opt/nanotrt/lib/libtrt_shim.so', mode=os.RTLD_LOCAL | os.RTLD_DEEPBIND)
        P, I = ctypes.c_void_p, ctypes.c_int
        _lib.trt_load.restype, _lib.trt_load.argtypes = P, [ctypes.c_char_p]
        _lib.trt_nbindings.argtypes = [P]
        _lib.trt_name.restype, _lib.trt_name.argtypes = ctypes.c_char_p, [P, I]
        _lib.trt_info.argtypes = [P, I, ctypes.POINTER(I), ctypes.POINTER(I), ctypes.POINTER(I)]
        _lib.trt_run.argtypes = [P, ctypes.POINTER(P), P]
    return _lib


class TRTModule:
    def __init__(self, engine_path):
        torch.zeros(1, device='cuda')            # create PyTorch's CUDA context first; TensorRT joins it
        L = _shim()
        self.h = L.trt_load(os.fsencode(engine_path))
        if not self.h:
            raise RuntimeError(f'cannot load TensorRT engine {engine_path}')
        self.n = L.trt_nbindings(self.h)
        self.inputs, self.outputs = [], []        # (binding index, name, shape, dtype)
        for i in range(self.n):
            d, inp, dt = (ctypes.c_int * 8)(), ctypes.c_int(), ctypes.c_int()
            rank = L.trt_info(self.h, i, d, ctypes.byref(inp), ctypes.byref(dt))
            b = (i, L.trt_name(self.h, i).decode(), tuple(d[:rank]), _DT[dt.value])
            (self.inputs if inp.value else self.outputs).append(b)

    def __call__(self, *xs):
        ptrs = (ctypes.c_void_p * self.n)()
        keep = []
        for (i, name, shape, dt), x in zip(self.inputs, xs):
            x = x.to('cuda', dt).contiguous()
            if tuple(x.shape) != shape:
                raise ValueError(f'input {name}: shape {tuple(x.shape)}, engine expects {shape}')
            keep.append(x); ptrs[i] = x.data_ptr()
        outs = []
        for i, name, shape, dt in self.outputs:
            outs.append(torch.empty(shape, dtype=dt, device='cuda')); ptrs[i] = outs[-1].data_ptr()
        if _shim().trt_run(self.h, ptrs, torch.cuda.current_stream().cuda_stream) != 0:
            raise RuntimeError('TensorRT enqueue failed')
        return outs[0] if len(outs) == 1 else tuple(outs)


def export(model, example, path, opset=11):
    """Export a torch model to ONNX in the form TensorRT 8.0's parser accepts (opset 11, IR 6, no Identity on weights)."""
    import onnx                                   # pip install onnx (done by install.sh)
    model = model.float().eval().cpu()
    with torch.no_grad():
        torch.onnx.export(model, example.float().cpu(), path, opset_version=opset, dynamo=False,
                          input_names=['input'], do_constant_folding=True)
    p = onnx.load(path); g = p.graph; inits = {i.name for i in g.initializer}; ren = {}
    for n in list(g.node):                        # the exporter shares weights through Identity nodes; TRT 8.0 wants
        if n.op_type == 'Identity' and n.input[0] in inits:   # Conv weights as initializers
            ren[n.output[0]] = n.input[0]; g.node.remove(n)
    for n in g.node:
        n.input[:] = [ren.get(x, x) for x in n.input]
    for o in g.output:
        if o.name in ren:
            o.name = ren[o.name]
    p.ir_version = 6
    onnx.checker.check_model(p); onnx.save(p, path)
    return path
