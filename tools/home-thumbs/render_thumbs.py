"""家具の GLB から、模様替えの「追加 → 家具」に出す画像を作る (Blender で動かす)。

    blender --background --factory-startup --python tools/home-thumbs/render_thumbs.py

backend/static/home/modules/<id>.glb を 1 つずつ読み、斜め前の少し上から正投影で撮って、
backend/static/home/thumbs/<id>.webp (背景は透明) に書く。家具の GLB を差し替えたら作り直す。
引数で家具の id を渡すと、その家具だけを作り直す (`-- home_stool bench_oak`)。
"""

import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[2]
MODULES = ROOT / "backend/static/home/modules"
OUT = ROOT / "backend/static/home/thumbs"

SIZE = 320  # 画面では 2 倍の解像度で 160px 四方ほどに出す
MARGIN = 1.12  # 家具のまわりの余白 (正投影の幅の倍率)
# 家具の正面は glTF の +Z (Blender の -Y)。正面から右へ回り込み、少し上から見下ろす
YAW = math.radians(32)
PITCH = math.radians(24)


def reset_scene() -> bpy.types.Scene:
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    try:
        scene.render.engine = "BLENDER_EEVEE"
    except TypeError:
        scene.render.engine = "CYCLES"
        scene.cycles.samples = 64
    scene.render.resolution_x = SIZE
    scene.render.resolution_y = SIZE
    scene.render.film_transparent = True
    scene.view_settings.view_transform = "Standard"
    scene.render.image_settings.file_format = "WEBP"
    scene.render.image_settings.color_mode = "RGBA"
    scene.render.image_settings.quality = 88

    world = bpy.data.worlds.new("World")
    world.use_nodes = True
    bg = next(n for n in world.node_tree.nodes if n.type == "BACKGROUND")
    bg.inputs[0].default_value = (1.0, 0.98, 0.95, 1.0)
    bg.inputs[1].default_value = 0.9
    scene.world = world
    return scene


def mesh_bounds(objects) -> tuple[Vector, Vector]:
    lo = Vector((math.inf,) * 3)
    hi = Vector((-math.inf,) * 3)
    for obj in objects:
        if obj.type != "MESH":
            continue
        for corner in obj.bound_box:
            p = obj.matrix_world @ Vector(corner)
            lo = Vector(map(min, lo, p))
            hi = Vector(map(max, hi, p))
    return lo, hi


def add_sun(scene, name, energy, rot):
    light = bpy.data.lights.new(name, "SUN")
    light.energy = energy
    light.angle = math.radians(8)
    obj = bpy.data.objects.new(name, light)
    obj.rotation_euler = rot
    scene.collection.objects.link(obj)


def render(glb: Path) -> None:
    scene = reset_scene()
    bpy.ops.import_scene.gltf(filepath=str(glb))
    lo, hi = mesh_bounds(scene.objects)
    center = (lo + hi) / 2

    # カメラの向き: 正面 (-Y) から右 (+X) へ YAW、上から PITCH
    direction = Vector((math.sin(YAW) * math.cos(PITCH), -math.cos(YAW) * math.cos(PITCH), math.sin(PITCH)))
    cam_data = bpy.data.cameras.new("Camera")
    cam_data.type = "ORTHO"
    cam = bpy.data.objects.new("Camera", cam_data)
    scene.collection.objects.link(cam)
    radius = (hi - lo).length
    cam.location = center + direction * (radius * 3 + 1)
    cam.rotation_euler = (-direction).to_track_quat("-Z", "Y").to_euler()
    cam_data.clip_end = radius * 10 + 10

    # 箱の 8 つの角をカメラの面に写して、収まる幅を決める (正方形なので縦横の大きいほう)
    bpy.context.view_layer.update()
    inv = cam.matrix_world.inverted()
    pts = [inv @ Vector((x, y, z)) for x in (lo.x, hi.x) for y in (lo.y, hi.y) for z in (lo.z, hi.z)]
    xs = [p.x for p in pts]
    ys = [p.y for p in pts]
    cam_data.ortho_scale = max(max(xs) - min(xs), max(ys) - min(ys)) * MARGIN
    # 写った範囲の中心へカメラをずらす (箱の中心と写った範囲の中心は少しずれる)
    shift = Vector(((max(xs) + min(xs)) / 2, (max(ys) + min(ys)) / 2, 0))
    cam.location = cam.matrix_world @ shift
    scene.camera = cam

    add_sun(scene, "Key", 3.2, (math.radians(50), 0, math.radians(30)))
    add_sun(scene, "Fill", 1.0, (math.radians(65), 0, math.radians(-120)))

    out = OUT / f"{glb.stem}.webp"
    scene.render.filepath = str(out)
    bpy.ops.render.render(write_still=True)
    print(f"[thumbs] {out.relative_to(ROOT)}")


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    only = sys.argv[sys.argv.index("--") + 1 :] if "--" in sys.argv else []
    glbs = sorted(MODULES.glob("*.glb"))
    if only:
        glbs = [g for g in glbs if g.stem in only]
    for glb in glbs:
        render(glb)
    print(f"[thumbs] {len(glbs)} files")


main()
