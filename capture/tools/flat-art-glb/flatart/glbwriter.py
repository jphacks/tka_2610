"""Minimal, dependency-free binary glTF 2.0 (.glb) writer."""
import json
import struct

import numpy as np

FLOAT, UINT16, UINT32 = 5126, 5123, 5125
ARRAY_BUFFER, ELEMENT_ARRAY_BUFFER = 34962, 34963


class GLB:
    def __init__(self, generator):
        self.bin = bytearray()
        self.j = {
            'asset': {'version': '2.0', 'generator': generator},
            'scene': 0, 'scenes': [{'nodes': []}], 'nodes': [], 'meshes': [],
            'materials': [], 'textures': [], 'images': [], 'samplers': [],
            'accessors': [], 'bufferViews': [], 'buffers': [{}],
        }

    # ---- raw data -------------------------------------------------------
    def _view(self, data, target=None):
        while len(self.bin) % 4:
            self.bin.append(0)
        v = {'buffer': 0, 'byteOffset': len(self.bin), 'byteLength': len(data)}
        if target:
            v['target'] = target
        self.bin += data
        self.j['bufferViews'].append(v)
        return len(self.j['bufferViews']) - 1

    def accessor(self, arr, kind):
        """kind: 'pos' | 'vec3' | 'vec4' | 'vec2' | 'idx'"""
        if kind == 'idx':
            a = np.ascontiguousarray(arr).reshape(-1)
            if a.max() < 65535:
                a, ct = a.astype('<u2'), UINT16
            else:
                a, ct = a.astype('<u4'), UINT32
            acc = {'bufferView': self._view(a.tobytes(), ELEMENT_ARRAY_BUFFER),
                   'componentType': ct, 'count': int(a.size), 'type': 'SCALAR'}
        else:
            a = np.ascontiguousarray(arr, dtype='<f4')
            assert np.isfinite(a).all(), 'non-finite vertex data'
            typ = {'pos': 'VEC3', 'vec3': 'VEC3', 'vec4': 'VEC4', 'vec2': 'VEC2'}[kind]
            acc = {'bufferView': self._view(a.tobytes(), ARRAY_BUFFER),
                   'componentType': FLOAT, 'count': int(a.shape[0]), 'type': typ}
            if kind == 'pos':
                acc['min'] = [float(v) for v in a.min(0)]
                acc['max'] = [float(v) for v in a.max(0)]
        self.j['accessors'].append(acc)
        return len(self.j['accessors']) - 1

    # ---- textures / materials -------------------------------------------
    def sampler(self, repeat):
        wrap = 10497 if repeat else 33071
        self.j['samplers'].append({'magFilter': 9729, 'minFilter': 9987, 'wrapS': wrap, 'wrapT': wrap})
        return len(self.j['samplers']) - 1

    def texture(self, data, mime, name, sampler):
        self.j['images'].append({'bufferView': self._view(data), 'mimeType': mime, 'name': name})
        self.j['textures'].append({'source': len(self.j['images']) - 1, 'sampler': sampler, 'name': name})
        return len(self.j['textures']) - 1

    def material(self, name, base_factor=(1, 1, 1), base_tex=None, normal_tex=None, normal_uv=0,
                 normal_scale=1.0, orm_tex=None, occ_tex=None, occ_strength=1.0,
                 roughness=0.9, double_sided=False, specular=None):
        pbr = {'baseColorFactor': [float(c) for c in base_factor] + [1.0],
               'metallicFactor': 0.0, 'roughnessFactor': float(roughness)}
        if base_tex is not None:
            pbr['baseColorTexture'] = {'index': base_tex}
        m = {'name': name, 'pbrMetallicRoughness': pbr, 'doubleSided': bool(double_sided)}
        if orm_tex is not None:
            pbr['metallicRoughnessTexture'] = {'index': orm_tex}
            pbr['roughnessFactor'] = 1.0
            pbr['metallicFactor'] = 1.0          # the texture's blue channel is 0
            m['occlusionTexture'] = {'index': orm_tex, 'strength': float(occ_strength)}
        if occ_tex is not None:
            m['occlusionTexture'] = {'index': occ_tex, 'strength': float(occ_strength)}
        if normal_tex is not None:
            m['normalTexture'] = {'index': normal_tex, 'texCoord': int(normal_uv), 'scale': float(normal_scale)}
        if specular is not None:
            # photo-derived albedo already contains the surface's own sheen
            m['extensions'] = {'KHR_materials_specular': {'specularFactor': float(specular)}}
            used = self.j.setdefault('extensionsUsed', [])
            if 'KHR_materials_specular' not in used:
                used.append('KHR_materials_specular')
        self.j['materials'].append(m)
        return len(self.j['materials']) - 1

    # ---- geometry ---------------------------------------------------------
    def primitive(self, material, pos, idx, normal, tangent=None, uv0=None, uv1=None):
        attrs = {'POSITION': self.accessor(pos, 'pos'), 'NORMAL': self.accessor(normal, 'vec3')}
        if tangent is not None:
            attrs['TANGENT'] = self.accessor(tangent, 'vec4')
        if uv0 is not None:
            attrs['TEXCOORD_0'] = self.accessor(uv0, 'vec2')
        if uv1 is not None:
            attrs['TEXCOORD_1'] = self.accessor(uv1, 'vec2')
        return {'attributes': attrs, 'indices': self.accessor(idx, 'idx'), 'material': material, 'mode': 4}

    def mesh_node(self, name, primitives, extras=None, parent=None):
        self.j['meshes'].append({'name': name, 'primitives': primitives})
        node = {'name': name, 'mesh': len(self.j['meshes']) - 1}
        if extras:
            node['extras'] = extras
        return self._add_node(node, parent)

    def group_node(self, name, extras=None, parent=None):
        node = {'name': name, 'children': []}
        if extras:
            node['extras'] = extras
        return self._add_node(node, parent)

    def _add_node(self, node, parent):
        self.j['nodes'].append(node)
        i = len(self.j['nodes']) - 1
        if parent is None:
            self.j['scenes'][0]['nodes'].append(i)
        else:
            self.j['nodes'][parent].setdefault('children', []).append(i)
        return i

    # ---- output -----------------------------------------------------------
    def save(self, path):
        j = {k: v for k, v in self.j.items() if not (isinstance(v, list) and len(v) == 0)}
        while len(self.bin) % 4:
            self.bin.append(0)
        j['buffers'] = [{'byteLength': len(self.bin)}]
        js = json.dumps(j, separators=(',', ':'), ensure_ascii=False).encode('utf-8')
        js += b' ' * ((4 - len(js) % 4) % 4)
        total = 12 + 8 + len(js) + 8 + len(self.bin)
        with open(path, 'wb') as fh:
            fh.write(struct.pack('<4sII', b'glTF', 2, total))
            fh.write(struct.pack('<I4s', len(js), b'JSON'))
            fh.write(js)
            fh.write(struct.pack('<I4s', len(self.bin), b'BIN\x00'))
            fh.write(bytes(self.bin))
        return total
