"""kt — fast Katachi models from photos with templates.

  kt sheet <folder>                         resolve .url links, make one contact sheet of all photos
  kt box     --front F [--back B --side S] --size 183x233[x22] [--kind book|box]
  kt bottle  --front F --side S [--back B --side2 S2] --height-cm 20 [--cap auto|none|plain|ribbed]
  kt flat    --photo P (--width-cm W | --height-cm H) [--thickness-mm 1.5] [--mode auto|rect|cutout]
  kt revolve --photo P --height-cm H [--hollow --wall-mm 3]
common: --title T  --out DIR  --ui (also register in the running web app)  --render-size 768

  kt auto <folder | photos...> --size 16,10.6,6.6        the AI picks the route (template or generator), then it runs
  kt gen --photo main=P@yaw,pitch [--photo ...] --size X,Y,Z   curved objects: Hunyuan3D-2.1 shape (setup_gen.ps1 / .sh)

  kt viewer install|uninstall|status [--katachi DIR]   process viewer page in Katachi's web UI
"""
from __future__ import annotations
import argparse
import importlib
import sys
from pathlib import Path

TEMPLATES = ('box', 'bottle', 'flat', 'revolve')


def _default_out(args, cmd):
    first = next(Path(v) for k, v in vars(args).items() if k in ('front', 'photo') and v)
    base = first.parent.parent if first.parent.name.lower() == 'jpg' else first.parent
    return base / f'3d_{cmd}'


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog='kt', description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    s = sub.add_parser('sheet', help='contact sheet of a photo folder')
    s.add_argument('folder')
    for name in TEMPLATES:
        mod = importlib.import_module(f'kt.templates.{name}')
        p = sub.add_parser(name, help=(mod.__doc__ or '').strip().splitlines()[0])
        mod.add_args(p)
        p.add_argument('--title'); p.add_argument('--out')
        p.add_argument('--ui', action='store_true', help='also register in the running Katachi web app (slower)')
        p.add_argument('--server', default='http://127.0.0.1:8765')
        p.add_argument('--render-size', type=int, default=768)
        p.add_argument('--fill', choices=['auto', 'paper', 'lama'], default=None,
                       help="how a hand's hole is filled when no other photo shows it: paper (surrounding paper), lama "
                            "(paper + the LaMa network where an illustration runs into the hole; needs the model, see README), "
                            "auto (default: lama when the model is installed)")
        p.add_argument('--fit', type=int, default=0, help="Katachi local numeric fitting: number of evaluations "
                       "(0 = off). Uses the template's bounded controls (bottle, revolve) and the photo outlines.")
    ins = sub.add_parser('inspect', help='measure photos in cm for writing a recipe by hand (face / edge / views)')
    isub = ins.add_subparsers(dest='what', required=True)
    f = isub.add_parser('face', help='a flat face of known size: rectified image, corner rounding, colour, marks')
    f.add_argument('--photo', required=True); f.add_argument('--size', required=True, help='WxH in cm, e.g. 22.12x31.26')
    f.add_argument('--corners', help='JSON [[x,y] x4] normalised TL TR BR BL, if the detection is wrong')
    f.add_argument('--facing', choices=['front', 'back'], default='front',
                   help='back: the photo sees the model from behind (yaw 180); mirrors x of the centred (recipe) coordinates')
    e = isub.add_parser('edge', help='a thin side of known length and thickness: recesses along it, seams')
    e.add_argument('--photo', required=True); e.add_argument('--length', type=float, required=True, help='cm')
    e.add_argument('--thickness', type=float, required=True, help='cm')
    e.add_argument('--ends', help='x1,y1,x2,y2 (0..1 of the photo): where the side starts and ends (most reliable: scale from the length)')
    e.add_argument('--at', help='x,y (0..1 of the photo) of a point on the side: the strip is traced from there')
    e.add_argument('--colour', help="r,g,b 0..1 of the side (e.g. a face's darker_half_rgb); finds the strip by colour")
    vw = isub.add_parser('views', help='the model from 7 directions, and next to each photo from its direction')
    vw.add_argument('--glb', required=True); vw.add_argument('--photo', action='append', default=[], help='key=path@yaw[,pitch]')
    for q in (f, e, vw):
        q.add_argument('--out', required=True)
    rc = sub.add_parser('recipe', help='build a hand-written recipe (scene.json) with the same checks as the templates')
    rc.add_argument('--scene', required=True); rc.add_argument('--photo', action='append', default=[], help='key=path@yaw[,pitch]')
    rc.add_argument('--mask', choices=['quad', 'rembg', 'none'], default='quad')
    rc.add_argument('--regions', help='JSON list of photo textures to cut out (see kt/recipe.py)')
    rc.add_argument('--out', required=True); rc.add_argument('--title'); rc.add_argument('--render-size', type=int, default=768)
    au = sub.add_parser('auto', help='one command for any object: the AI chooses the route (a template, or the shape generator)')
    au.add_argument('inputs', nargs='+', help='a photo folder (.url links are resolved) or photo files')
    au.add_argument('--size', required=True, help='known dimensions in cm, 1-3 numbers in any order, e.g. 16,10.6,6.6')
    au.add_argument('--out'); au.add_argument('--ai-model', default='sonnet')
    g = sub.add_parser('gen', help='a curved / free-form object as a generated mesh (Hunyuan3D-2.1 on the local GPU)')
    g.add_argument('--photo', action='append', required=True,
                   help='key=path@yaw[,pitch]; the first photo is the one the shape is generated from, the others are compared')
    g.add_argument('--size', required=True, help='X,Y,Z in cm: width (x), height (y, up), depth (z)')
    g.add_argument('--steps', type=int, help='generation steps (default 50 on CUDA, 30 on MPS / CPU)')
    g.add_argument('--octree', type=int, help='surface grid resolution (default 384 on CUDA, 256 on MPS / CPU)')
    g.add_argument('--guidance', type=float, default=5.0); g.add_argument('--seed', type=int, default=1234)
    g.add_argument('--max-faces', type=int, default=100000)
    g.add_argument('--material', choices=['regions', 'one'], default='regions',
                   help='regions: photo colours projected, grouped, one AI call per model gives each region a material and '
                        'keeps real marks (default); one: a single material for the whole model')
    g.add_argument('--ai-model', default='sonnet', help='model for the material decision (Claude Code model name)')
    g.add_argument('--out'); g.add_argument('--title'); g.add_argument('--render-size', type=int, default=768)
    v = sub.add_parser('viewer', help="install the read-only process viewer into Katachi's web UI")
    v.add_argument('action', choices=('install', 'uninstall', 'status'))
    v.add_argument('--katachi', help="Katachi folder (or its web folder); default: the installed katachi package")
    args = ap.parse_args(argv)

    if args.cmd == 'viewer':
        from .viewer import main as viewer_main
        return viewer_main(args)

    if args.cmd == 'inspect':
        import json
        from . import inspect as ki
        from .recipe import parse_photo
        if args.what == 'face':
            size = [float(v) for v in args.size.lower().split('x')]
            res = ki.measure_face(args.photo, size, args.out, corners=json.loads(args.corners) if args.corners else None,
                                  facing=args.facing)
        elif args.what == 'edge':
            res = ki.measure_edge(args.photo, args.length, args.thickness, args.out,
                                  colour_rgb=[float(v) for v in args.colour.split(',')] if args.colour else None,
                                  at=[float(v) for v in args.at.split(',')] if args.at else None,
                                  ends=[float(v) for v in args.ends.split(',')] if args.ends else None)
        else:
            res = {'sheet': ki.views_sheet(args.glb, Path(args.out), dict(parse_photo(p) for p in args.photo))}
        brief = {k: v for k, v in res.items() if k not in ('marks',)}
        if 'marks' in res:
            brief['marks'] = [{k: v for k, v in mk.items() if k != 'outline_centred_cm'} for mk in res['marks']]
        print(json.dumps(brief, ensure_ascii=False, indent=1))
        return 0

    if args.cmd == 'recipe':
        from .recipe import build, parse_photo
        rep = build(args.scene, dict(parse_photo(p) for p in args.photo), args.out, args.mask, args.regions,
                    args.render_size, args.title)
        return 2 if rep['quality']['status'] == 'error' else 0

    if args.cmd == 'auto':
        from .auto import run as auto_run
        size = [float(v) for v in args.size.replace('x', ',').split(',') if v.strip()]
        return auto_run(args.inputs, size, args.out, args.ai_model)

    if args.cmd == 'gen':
        from .gen import build as gen_build
        from .recipe import parse_photo
        photos = dict(parse_photo(p) for p in args.photo)
        size = [float(v) for v in args.size.replace('x', ',').split(',')]
        if len(size) != 3:
            raise SystemExit('--size needs three numbers: width,height,depth in cm')
        first = Path(next(iter(photos.values()))[0])
        out = Path(args.out) if args.out else (first.parent.parent if first.parent.name.lower() == 'jpg' else first.parent) / '3d_gen'
        print(f'kt gen -> {out}')
        rep = gen_build(photos, size, out, {'steps': args.steps, 'octree': args.octree, 'guidance': args.guidance,
                                            'seed': args.seed, 'max_faces': args.max_faces},
                        ai_model=args.ai_model, title=args.title, render_size=args.render_size, material=args.material)
        return 2 if rep['quality']['status'] == 'error' else 0

    if args.cmd == 'sheet':
        from .photos import resolve_folder, contact_sheet
        folder = Path(args.folder)
        paths = resolve_folder(folder)
        out = contact_sheet(paths, folder / '_sheet.jpg')
        for i, p in enumerate(paths, 1):
            print(f'{i}: {p}')
        print(f'sheet: {out}')
        return 0

    from .engine import Workspace
    from .report import Timer, finish
    out = Path(args.out) if args.out else _default_out(args, args.cmd)
    out.mkdir(parents=True, exist_ok=True)
    print(f'kt {args.cmd} -> {out}')
    timer = Timer()
    ws = Workspace(out)
    mod = importlib.import_module(f'kt.templates.{args.cmd}')
    if getattr(args, 'fill', None):
        from . import hands
        hands.FILL_METHOD = args.fill
    plan = mod.plan(args, ws, timer)
    if args.fit:
        plan.extra['local_fit'] = args.fit
    build = ws.execute(plan, args.render_size, timer)
    if build['result'].get('stop_reason') not in ('local-recipe-complete',):
        plan.warnings.append(f"katachi stop reason: {build['result'].get('stop_reason')}")
    if args.ui:
        from .publish import publish
        info = publish(ws, plan, args.server)
        plan.notes.append(f"web UI: project {info['project_id']} job {info['job_id']} ({info['status']})")
        timer.mark('publish to web UI')
    report = finish(ws, plan, build, timer, out, args.cmd, {k: v for k, v in vars(args).items() if k != 'cmd'})
    return 2 if report['quality']['status'] == 'error' else 0


if __name__ == '__main__':
    sys.exit(main())
