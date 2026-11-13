#!/usr/bin/env python3
"""CLI for flat-art-glb.

  python3 flatart_glb.py build CONFIG.json --out DIR
  python3 flatart_glb.py check DIR
"""
import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))


def main(argv=None):
    ap = argparse.ArgumentParser(prog='flatart_glb.py', description='photo of a flat artwork -> GLB')
    sub = ap.add_subparsers(dest='cmd', required=True)
    b = sub.add_parser('build', help='build model.glb, report.json and overlay.jpg')
    b.add_argument('config')
    b.add_argument('--out', required=True, help='output folder (keep it outside the repository)')
    c = sub.add_parser('check', help='validate the GLB, render it and write compare.jpg')
    c.add_argument('dir')
    a = ap.parse_args(argv)
    if a.cmd == 'build':
        from flatart.build import build
        build(a.config, a.out)
        return 0
    from flatart.check import check
    return 0 if check(a.dir) else 1


if __name__ == '__main__':
    sys.exit(main())
