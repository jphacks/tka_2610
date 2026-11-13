"""flat-art-glb: one photo of a flat children's artwork -> GLB.

Modules can be used on their own:
  rectify  - sheet detection, edge-line fit, homography (Rectifier)
  segment  - Lab colour classification (ColorClassifier), piece extraction
  layers   - layer numbers, completion of parts hidden under upper pieces
  texture  - illumination gain map, white balance, inpainting, piece textures
  mesh     - outline polygon from a mask, extrusion to paper thickness
  glbwriter- dependency-free GLB writer
  build    - the whole pipeline (build(config_path, out_dir))
  check    - validation, headless renders and compare.jpg
"""
__version__ = '0.1.0'
