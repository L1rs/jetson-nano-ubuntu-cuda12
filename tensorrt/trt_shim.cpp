// SPDX-License-Identifier: MIT
// Minimal C interface to TensorRT 8.0 (from the user's own JetPack 4.6 install) for Python ctypes.
// Built by install.sh under L4T: g++ -O2 -shared -fPIC trt_shim.cpp -lnvinfer (see tensorrt/build.sh).
#include <NvInfer.h>
#include <cstdio>
#include <fstream>
#include <iterator>
#include <vector>
using namespace nvinfer1;

struct Log : ILogger {
  void log(Severity s, const char *m) noexcept override { if (s <= Severity::kWARNING) fprintf(stderr, "[TRT] %s\n", m); }
} gLog;
struct H { IRuntime *rt; ICudaEngine *eng; IExecutionContext *ctx; };

extern "C" {
void *trt_load(const char *path) {
  std::ifstream f(path, std::ios::binary);
  std::vector<char> b((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
  if (b.empty()) return nullptr;
  H *h = new H{createInferRuntime(gLog), nullptr, nullptr};
  h->eng = h->rt->deserializeCudaEngine(b.data(), b.size());
  if (!h->eng) return nullptr;
  h->ctx = h->eng->createExecutionContext();
  return h->ctx ? h : nullptr;
}
int trt_nbindings(H *h) { return h->eng->getNbBindings(); }
const char *trt_name(H *h, int i) { return h->eng->getBindingName(i); }
// dims[8] <- shape, returns rank; *is_input, *dtype (0 float, 1 half, 2 int8, 3 int32, 4 bool)
int trt_info(H *h, int i, int *dims, int *is_input, int *dtype) {
  Dims d = h->eng->getBindingDimensions(i);
  for (int k = 0; k < d.nbDims && k < 8; k++) dims[k] = d.d[k];
  *is_input = h->eng->bindingIsInput(i);
  *dtype = (int)h->eng->getBindingDataType(i);
  return d.nbDims;
}
// bindings: device pointers in binding order; stream: CUstream (e.g. torch.cuda.current_stream().cuda_stream)
int trt_run(H *h, void **bindings, void *stream) { return h->ctx->enqueueV2(bindings, (cudaStream_t)stream, nullptr) ? 0 : -1; }
}
