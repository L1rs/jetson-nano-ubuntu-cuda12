import re
f="/work/pytorch/build/build.ninja"; s=open(f).read()
pat=re.compile(r"(build caffe2/CMakeFiles/torch_cuda\.dir/[^\n]*/(?:Conv_v8|MHA|RegisterCUDA[_0-9]*|RegisterNestedTensorCUDA[_0-9]*|GroupMM|ScaledGroupMM|RowwiseScaledMM|ScaledBlas|Blas|MixedDtypesLinear|int4mm|[^/\n]*[Cc]utlass[^/\n]*|SegmentReduce|Sort|Sorting|TensorTopK|Unique|ReduceMinMax[^/\n]*|layer_norm_kernel|Indexing|Embedding[^/\n]*)\.cu\.o:[^\n]*\n(?:  [^\n]*\n)*)")
n=0
def add(m):
    global n
    b=m.group(1)
    if "pool = heavy" in b: return b
    n+=1; return b+"  pool = heavy\n"
s=pat.sub(add,s); open(f,"w").write(s); print("heavy cuda edges added",n)
# torch_python: grosse Binding-Dateien (script_init.cpp: OOM bei -j8)
s=open(f).read()
pat2=re.compile(r"(build caffe2/torch/CMakeFiles/torch_python\.dir/[^\n]*/(?:script_init|init|python_torch_functions[^/\n]*|python_variable_methods|python_nn_functions|python_functions[^/\n]*|python_return_types|python_variable|python_ir|pybind_utils|python_sugared_value|python_tracer|tensor_new|python_sparse_functions|python_special_functions|python_linalg_functions|python_fft_functions|python_nested_functions|python_enum_tag)\.cpp\.o:[^\n]*\n(?:  [^\n]*\n)*)")
n=0
s=pat2.sub(add,s); open(f,"w").write(s); print("heavy torch_python edges added",n)
