"""Shape generation with Hunyuan3D-2.1 (shape only). Run by kt.gen with the generator's own Python
(setup_gen.ps1 / setup_gen.sh); kt never imports this file, so torch stays out of the tools venv.

  python -I hy3d_worker.py --code <Hunyuan3D-2.1 dir> --image cutout.png --out mesh.glb [--device cuda|mps|cpu]
                           [--steps 50 --octree 384 --guidance 5.0 --seed 1234 --max-faces 100000]

The image is an RGBA cut-out (background transparent). Weights are read from $HY3DGEN_MODELS
(tencent/Hunyuan3D-2.1/hunyuan3d-dit-v2-1). Prints one JSON line with timings and mesh stats.

Hunyuan's shape code is used unchanged. Off CUDA (Apple silicon MPS, or CPU) one thing is switched at run time:
its attention layers request CUDA-only kernels (torch.backends.cuda.sdp_kernel with the math kernel disabled);
there that request is a no-op, so PyTorch picks the device's own kernel. The weights load onto --device (fp16;
fp32 on CPU). kt.gen sets PYTORCH_ENABLE_MPS_FALLBACK=1 for MPS before torch starts.
Hunyuan3D 2.1 is under the Tencent Hunyuan 3D 2.1 Community License (see the LICENSE in --code).
"""
import argparse
import contextlib
import json
import os
import platform
import sys
import time

t0 = time.perf_counter()
ap = argparse.ArgumentParser()
ap.add_argument('--code', required=True)
ap.add_argument('--image', required=True)
ap.add_argument('--out', required=True)
ap.add_argument('--device', default='cuda', choices=['cuda', 'mps', 'cpu'])
ap.add_argument('--steps', type=int, default=50)
ap.add_argument('--octree', type=int, default=384)
ap.add_argument('--guidance', type=float, default=5.0)
ap.add_argument('--seed', type=int, default=1234)
ap.add_argument('--max-faces', type=int, default=100000)
args = ap.parse_args()
sys.path.insert(0, os.path.join(args.code, 'hy3dshape'))

import torch                                                    # noqa: E402

dev = args.device
if dev != 'cuda':
    torch.backends.cuda.sdp_kernel = lambda *a, **k: contextlib.nullcontext()


def sync():
    if dev == 'cuda':
        torch.cuda.synchronize()
    elif dev == 'mps':
        torch.mps.synchronize()


from PIL import Image                                           # noqa: E402
from hy3dshape.pipelines import Hunyuan3DDiTFlowMatchingPipeline  # noqa: E402
from hy3dshape.postprocessors import FloaterRemover, DegenerateFaceRemover, FaceReducer  # noqa: E402

t_import = time.perf_counter()
pipe = Hunyuan3DDiTFlowMatchingPipeline.from_pretrained('tencent/Hunyuan3D-2.1', device=dev,
                                                        dtype=torch.float32 if dev == 'cpu' else torch.float16)
sync()
t_load = time.perf_counter()
image = Image.open(args.image).convert('RGBA')
mesh = pipe(image=image, num_inference_steps=args.steps, octree_resolution=args.octree, guidance_scale=args.guidance,
            generator=torch.manual_seed(args.seed), enable_pbar=False)[0]
sync()
t_gen = time.perf_counter()
if mesh is None:
    sys.exit(f'no surface was found in the generated volume (steps {args.steps}, octree {args.octree}): '
             'too few steps or too coarse a grid, or the cut-out does not show an object')
raw_faces = int(len(mesh.faces))
mesh = FloaterRemover()(mesh)
mesh = DegenerateFaceRemover()(mesh)
mesh = FaceReducer()(mesh, max_facenum=args.max_faces)
mesh.export(args.out)
t_post = time.perf_counter()
if dev == 'cuda':
    gpu, mem = torch.cuda.get_device_name(0), torch.cuda.max_memory_allocated()
elif dev == 'mps':
    gpu, mem = f'Apple {platform.machine()} (MPS)', torch.mps.driver_allocated_memory()   # current, not peak
else:
    gpu, mem = 'CPU', 0
print(json.dumps({
    'timings_s': {'import': round(t_import - t0, 2), 'load_model': round(t_load - t_import, 2),
                  'generate': round(t_gen - t_load, 2), 'postprocess': round(t_post - t_gen, 2)},
    'faces_raw': raw_faces, 'faces': int(len(mesh.faces)), 'vertices': int(len(mesh.vertices)),
    'bounds': [[float(v) for v in b] for b in mesh.bounds],
    'device': dev, 'gpu': gpu, 'max_gpu_memory_gb': round(mem / 1e9, 2),
    'settings': {'steps': args.steps, 'octree': args.octree, 'guidance': args.guidance, 'seed': args.seed,
                 'max_faces': args.max_faces},
}))
