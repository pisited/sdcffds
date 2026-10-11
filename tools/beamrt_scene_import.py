#!/usr/bin/env python3
"""BeamRT Collada (.dae) mesh extraction and local-space BVH preprocessing.

Offline tool; Python standard library only. It does NOT parse .cdae/.dts,
decode DDS textures, bake BeamNG TSStatic transforms, or upload GPU resources.
It never marks a material opaque just because no alpha field was found.

Single asset:
  python tools/beamrt_scene_import.py --input shape.dae --output shape.beamrt.json
Manifest batch:
  python tools/beamrt_scene_import.py --manifest beamrtSceneManifest.json \
      --assets-root EXTRACTED_GAME_ASSETS --output-dir beamrt_assets
Tests:
  python tools/beamrt_scene_import.py --self-test
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import sys
import tempfile
import xml.etree.ElementTree as ET

SCHEMA = "beamrt.mesh.asset.v1"
MAX_ASSET_TRIANGLES = 200000


def tag(e):
    return e.tag.rsplit("}", 1)[-1] if e is not None else ""


def children(e, name):
    return [c for c in e if tag(c) == name] if e is not None else []


def first(e, name):
    return next(iter(children(e, name)), None)


def descendants(e, name):
    return (c for c in e.iter() if tag(c) == name)


def strip_ref(value):
    return (value or "").lstrip("#")


def tokens(e):
    return (e.text or "").split() if e is not None else []


def positive_int(value, default):
    try:
        result = int(value)
        return result if result >= 0 else default
    except (TypeError, ValueError):
        return default


def float_stream(e, cap=3000000):
    words = tokens(e)
    if len(words) > cap:
        raise ValueError("source float array exceeds safety limit")
    vals = [float(v) for v in words]
    if not all(math.isfinite(v) for v in vals):
        raise ValueError("non-finite coordinates in Collada data")
    return vals


def parse_sources(mesh):
    sources = {}
    for src in children(mesh, "source"):
        sid = src.get("id")
        floats = first(src, "float_array")
        if not sid or floats is None:
            continue
        vals = float_stream(floats)
        tc = first(src, "technique_common")
        accessor = first(tc, "accessor")
        stride = positive_int(accessor.get("stride") if accessor is not None else None, 1)
        offset = positive_int(accessor.get("offset") if accessor is not None else None, 0)
        count = positive_int(accessor.get("count") if accessor is not None else None,
                             max(0, (len(vals) - offset) // max(1, stride)))
        if stride < 1 or stride > 32 or count > len(vals):
            raise ValueError("invalid source accessor " + sid)
        if offset + count * stride > len(vals):
            raise ValueError("source accessor exceeds float array: " + sid)
        sources[sid] = [vals[offset + i * stride:offset + (i + 1) * stride]
                        for i in range(count)]
    return sources


def parse_bindings(root):
    materials = {}
    for m in descendants(root, "material"):
        mid = m.get("id")
        if mid:
            materials[mid] = m.get("name") or mid
    by_geometry = {}
    for ig in descendants(root, "instance_geometry"):
        geom_id = strip_ref(ig.get("url"))
        if not geom_id:
            continue
        dest = by_geometry.setdefault(geom_id, {})
        for im in descendants(ig, "instance_material"):
            symbol = im.get("symbol")
            target = strip_ref(im.get("target"))
            if not symbol or not target:
                continue
            names = dest.setdefault(symbol, set())
            names.add(materials.get(target, target))
    # Conflicting bindings across different instances are intentionally unknown.
    return {gid: {sym: next(iter(names)) if len(names) == 1 else None
                  for sym, names in syms.items()}
            for gid, syms in by_geometry.items()}


def orient(value, scale, up):
    xyz = [float(value[i]) * scale for i in range(3)]
    if up == "Y_UP":
        return [xyz[0], -xyz[2], xyz[1]]
    if up == "X_UP":
        return [xyz[1], xyz[2], xyz[0]]
    return xyz


def face_area_sq(v):
    a, b, c = v
    u = [b[i] - a[i] for i in range(3)]
    w = [c[i] - a[i] for i in range(3)]
    q = [u[1] * w[2] - u[2] * w[1],
         u[2] * w[0] - u[0] * w[2],
         u[0] * w[1] - u[1] * w[0]]
    return sum(x * x for x in q)


def parse_geometry(mesh, geom_id, bindings, scale, up, triangle_limit):
    sources = parse_sources(mesh)
    vertex_aliases = {}
    for vert in children(mesh, "vertices"):
        alias = vert.get("id")
        for inp in children(vert, "input"):
            if inp.get("semantic") == "POSITION" and alias:
                vertex_aliases[alias] = strip_ref(inp.get("source"))
    faces = []
    skipped = {}
    def note(reason):
        skipped[reason] = skipped.get(reason, 0) + 1

    def decode_primitive(element, kind):
        inputs = []
        for inp in children(element, "input"):
            semantic = inp.get("semantic")
            ref = strip_ref(inp.get("source"))
            if semantic == "VERTEX":
                ref = vertex_aliases.get(ref)
                semantic = "POSITION"
            inputs.append((semantic, ref, positive_int(inp.get("offset"), 0),
                           positive_int(inp.get("set"), 0)))
        if not inputs:
            note("no inputs")
            return
        stride = max(item[2] for item in inputs) + 1
        if stride <= 0 or stride > 24:
            note("unsupported index stride")
            return
        pos = next((item for item in inputs if item[0] == "POSITION"), None)
        uv = next((item for item in inputs if item[0] == "TEXCOORD" and item[3] == 0), None)
        if uv is None:
            uv = next((item for item in inputs if item[0] == "TEXCOORD"), None)
        if pos is None or pos[1] not in sources:
            note("missing vertex position source")
            return
        material_symbol = element.get("material") or None

        def add_face(corners):
            if len(faces) >= triangle_limit:
                raise ValueError("asset exceeds --max-triangles; no partial mesh saved")
            vs, us = [], []
            try:
                for entry in corners:
                    vi = entry[pos[2]]
                    if vi < 0:
                        raise ValueError("negative vertex index")
                    original = sources[pos[1]][vi]
                    if len(original) < 3:
                        raise ValueError("position has less than XYZ")
                    vs.append(orient(original, scale, up))
                    if uv is not None and uv[1] in sources:
                        t = sources[uv[1]][entry[uv[2]]]
                        us.append([t[0], t[1]] if len(t) >= 2 else None)
            except (IndexError, KeyError, ValueError):
                note("bad source index")
                return
            if face_area_sq(vs) <= 1e-14:
                note("degenerate triangle")
                return
            faces.append({
                "v": vs,
                "uv": us if len(us) == 3 and all(p is not None for p in us) else None,
                "materialSymbol": material_symbol,
                "materialNameCandidate": bindings.get(material_symbol),
                "alphaMode": "unknown"
            })
        def entries(p):
            raw = [int(v) for v in tokens(p)]
            if len(raw) % stride:
                note("truncated primitive index array")
                return []
            return [raw[i:i+stride] for i in range(0, len(raw), stride)]
        if kind == "triangles":
            for p in children(element, "p"):
                data = entries(p)
                if len(data) % 3:
                    note("incomplete triangle array")
                    continue
                for i in range(0, len(data), 3):
                    add_face(data[i:i+3])
        elif kind == "polylist":
            count_element = first(element, "vcount")
            counts = [int(x) for x in tokens(count_element)]
            data = entries(first(element, "p"))
            cursor = 0
            for count in counts:
                if count < 3 or cursor + count > len(data):
                    note("invalid polygon vertex count")
                    break
                poly = data[cursor:cursor+count]
                cursor += count
                for i in range(1, count-1):
                    add_face([poly[0], poly[i], poly[i+1]])
            if cursor != len(data):
                note("polylist index count mismatch")
        elif kind == "polygons":
            for p in children(element, "p"):
                poly = entries(p)
                for i in range(1, len(poly)-1):
                    add_face([poly[0], poly[i], poly[i+1]])
            if children(element, "ph"):
                note("polygons with holes skipped")

    for primitive in mesh:
        kind = tag(primitive)
        if kind in ("triangles", "polylist", "polygons"):
            decode_primitive(primitive, kind)
        elif kind in ("trifans", "tristrips", "lines", "linestrips", "splines"):
            note("unsupported primitive " + kind)
    return faces, skipped


def bbox_triangle(face):
    coords = face["v"]
    return ([min(p[i] for p in coords) for i in range(3)],
            [max(p[i] for p in coords) for i in range(3)],
            [sum(p[i] for p in coords) / 3 for i in range(3)])


def build_bvh(faces, leaf_size=8):
    """CPU-built flat BVH with shared leaf triangle index stream.

    This data structure is ready for a future GPU-buffer upload, but no
    GPU resource or engine shader is bound by this tool.
    """
    if not faces:
        return {"nodes": [], "triangleIndices": [], "leafSize": leaf_size}
    bounds = [bbox_triangle(face) for face in faces]
    nodes, packed = [], []

    def make(indices):
        lo = [min(bounds[i][0][a] for i in indices) for a in range(3)]
        hi = [max(bounds[i][1][a] for i in indices) for a in range(3)]
        at = len(nodes)
        nodes.append(None)
        if len(indices) <= leaf_size:
            start = len(packed)
            packed.extend(indices)
            nodes[at] = {"min": lo, "max": hi, "left": -1, "right": -1,
                         "start": start, "count": len(indices)}
            return at
        cent_lo = [min(bounds[i][2][a] for i in indices) for a in range(3)]
        cent_hi = [max(bounds[i][2][a] for i in indices) for a in range(3)]
        axis = max(range(3), key=lambda a: cent_hi[a] - cent_lo[a])
        indices.sort(key=lambda i: bounds[i][2][axis])
        mid = len(indices) // 2
        left, right = make(indices[:mid]), make(indices[mid:])
        nodes[at] = {"min": lo, "max": hi, "left": left, "right": right,
                     "start": -1, "count": 0}
        return at

    make(list(range(len(faces))))
    return {"nodes": nodes, "triangleIndices": packed, "leafSize": leaf_size}


def extract(path, max_triangles=MAX_ASSET_TRIANGLES, with_bvh=True):
    path = Path(path)
    if path.suffix.lower() != ".dae":
        raise ValueError("only plain-text .dae is supported (not .cdae/.dts)")
    root = ET.parse(str(path)).getroot()
    if tag(root) != "COLLADA":
        raise ValueError("not a COLLADA root element")
    asset = first(root, "asset")
    unit = first(asset, "unit")
    scale = float(unit.get("meter", "1")) if unit is not None else 1.0
    if not math.isfinite(scale) or scale <= 0 or scale > 100000:
        raise ValueError("invalid Collada asset unit scale")
    up_element = first(asset, "up_axis")
    up = (up_element.text or "Y_UP").strip() if up_element is not None else "Y_UP"
    if up not in ("X_UP", "Y_UP", "Z_UP"):
        raise ValueError("unsupported Collada up_axis: " + up)
    bindings = parse_bindings(root)
    all_faces, skipped, geometry_counts = [], {}, {}
    for geom in descendants(root, "geometry"):
        mesh = first(geom, "mesh")
        if mesh is None:
            continue
        geom_id = geom.get("id") or "<unnamed>"
        remaining = max_triangles - len(all_faces)
        faces, warnings = parse_geometry(mesh, geom_id,
                                         bindings.get(geom_id, {}),
                                         scale, up, remaining)
        all_faces.extend(faces)
        geometry_counts[geom_id] = len(faces)
        for k, v in warnings.items():
            skipped[k] = skipped.get(k, 0) + v
    if not all_faces:
        raise ValueError("no supported mesh triangles found")
    result = {
        "schema": SCHEMA, "source": str(path), "meshLocal": True,
        "space": "asset-local metres, Z up (not BeamNG world-space)",
        "assetUnitsInMetres": scale, "originalUpAxis": up,
        "instanceTransformsBaked": False,
        "sceneNodeTransformsBaked": False,
        "opacityTexturesSampled": False,
        "opaqueFacesVerified": False,
        "gpuUploaded": False, "triangles": all_faces,
        "bvh": build_bvh(all_faces) if with_bvh else None,
        "stats": {"triangles": len(all_faces), "geometryCounts": geometry_counts,
                  "skipped": skipped, "materialSymbols":
                      sorted({f["materialSymbol"] for f in all_faces if f["materialSymbol"]}),
                  "uvTriangles": sum(f["uv"] is not None for f in all_faces)}
    }
    return result


def save_json(path, payload):
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    with p.open("w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))


def resolve_asset(root, shape_path):
    # Only files explicitly inside an extracted assets directory are opened.
    # ZIP, cdae and DTS require different decoders; never invent fallbacks.
    candidate = (root / shape_path.replace("\\", "/").lstrip("/")).resolve()
    root_resolved = root.resolve()
    if os.path.commonpath([str(root_resolved), str(candidate)]) != str(root_resolved):
        raise ValueError("asset path escapes --assets-root")
    return candidate


def batch(manifest_path, assets_root, output_dir, limit, max_triangles, with_bvh):
    data = json.loads(Path(manifest_path).read_text(encoding="utf-8"))
    if data.get("schema") != "beamrt.static.manifest.v1":
        raise ValueError("manifest has unexpected schema")
    assets = data.get("assets")
    if not isinstance(assets, dict):
        raise ValueError("manifest assets must be a mapping")
    root = Path(assets_root)
    destination = Path(output_dir)
    entries = []
    for shape_path in sorted(assets)[:limit]:
        name = Path(shape_path.replace("\\", "/")).name
        item = {"shapePath": shape_path, "instanceCount":
                assets[shape_path].get("instanceCount", 0), "status": "skipped"}
        if not name.lower().endswith(".dae"):
            item["reason"] = "unsupported .cdae/.dts/other asset"
        else:
            try:
                source = resolve_asset(root, shape_path)
                if not source.is_file():
                    raise FileNotFoundError("extracted .dae not found: " + str(source))
                parsed = extract(source, max_triangles, with_bvh)
                file_id = hashlib.sha256(shape_path.encode("utf-8")).hexdigest()[:12]
                output_name = file_id + "_" + Path(name).stem + ".beamrt.json"
                save_json(destination / output_name, parsed)
                item.update({"status": "imported", "output": output_name,
                             "triangles": parsed["stats"]["triangles"]})
            except (ValueError, OSError, ET.ParseError) as exc:
                item.update({"status": "failed", "reason": str(exc)})
        entries.append(item)
    index = {"schema": "beamrt.asset.batch.v1", "inputAssets": len(assets),
             "processedAssets": len(entries), "unprocessedAssets":
             max(0, len(assets) - len(entries)), "assets": entries,
             "gpuUploaded": False, "worldTransformsBaked": False,
             "verifiedCompleteScene": False}
    save_json(destination / "index.json", index)
    return index


SAMPLE = """<?xml version="1.0"?>
<COLLADA xmlns="http://www.collada.org/2005/11/COLLADASchema">
  <asset><unit meter="1"/><up_axis>Z_UP</up_axis></asset>
  <library_geometries><geometry id="wall"><mesh>
    <source id="positions"><float_array id="p" count="12">0 0 0 1 0 0 1 0 2 0 0 2</float_array>
      <technique_common><accessor source="#p" count="4" stride="3">
        <param name="X"/><param name="Y"/><param name="Z"/>
      </accessor></technique_common></source>
    <vertices id="verts"><input semantic="POSITION" source="#positions"/></vertices>
    <triangles count="2" material="wallpaint">
      <input semantic="VERTEX" source="#verts" offset="0"/>
      <p>0 1 2 0 2 3</p>
    </triangles>
  </mesh></geometry></library_geometries>
</COLLADA>"""


def self_test():
    with tempfile.TemporaryDirectory() as tmp:
        source = Path(tmp) / "sample.dae"
        source.write_text(SAMPLE, encoding="utf-8")
        result = extract(source)
        assert len(result["triangles"]) == 2
        assert len(result["bvh"]["triangleIndices"]) == 2
        assert result["stats"]["uvTriangles"] == 0
        assert result["triangles"][0]["alphaMode"] == "unknown"
        assert result["instanceTransformsBaked"] is False
        try:
            extract(source, max_triangles=1)
            raise AssertionError("triangle limit was ignored")
        except ValueError as exc:
            assert "max-triangles" in str(exc)
    return {"passed": True, "checks": 6, "doesNotTestGPU": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    modes = parser.add_mutually_exclusive_group(required=True)
    modes.add_argument("--input", help="one extracted plain-text .dae")
    modes.add_argument("--manifest", help="BeamRT in-game static scene JSON manifest")
    modes.add_argument("--self-test", action="store_true")
    parser.add_argument("--output", help="output JSON path for --input")
    parser.add_argument("--assets-root", help="root of extracted BeamNG assets")
    parser.add_argument("--output-dir", help="output folder for batch --manifest")
    parser.add_argument("--max-assets", type=int, default=32)
    parser.add_argument("--max-triangles", type=int, default=MAX_ASSET_TRIANGLES)
    parser.add_argument("--no-bvh", action="store_true")
    a = parser.parse_args()
    try:
        if a.self_test:
            print(json.dumps(self_test()))
        elif a.input:
            if not a.output:
                parser.error("--output is required with --input")
            result = extract(a.input, a.max_triangles, not a.no_bvh)
            save_json(a.output, result)
            print(json.dumps({"output": a.output, "stats": result["stats"],
                              "gpuUploaded": False}))
        else:
            if not a.assets_root or not a.output_dir:
                parser.error("--assets-root and --output-dir are required with --manifest")
            if not 1 <= a.max_assets <= 20000:
                parser.error("--max-assets must be between 1 and 20000")
            result = batch(a.manifest, a.assets_root, a.output_dir,
                           a.max_assets, a.max_triangles, not a.no_bvh)
            print(json.dumps({"processed": result["processedAssets"],
                              "imported": sum(e["status"] == "imported"
                                              for e in result["assets"]),
                              "index": str(Path(a.output_dir) / "index.json")}))
    except (ValueError, OSError, ET.ParseError) as exc:
        print("BeamRT import error: " + str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
