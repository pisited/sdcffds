"""Read-only, bounded inventory of the installed game's MessagePack shader cache.

Cache entries are evidence of cached compilation, never executing pass identity.
No cache writes, game loading, decompression guesses or graphics activation.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import struct

MAX_CACHE = 128 * 1024 * 1024
MAX_VALUE = 16 * 1024 * 1024
MAX_ITEMS = 100000


class CacheError(ValueError):
    pass


class Reader:
    def __init__(self, data: bytes):
        if len(data) > MAX_CACHE:
            raise CacheError("cache byte budget exceeded")
        self.data = data
        self.offset = 0
        self.values = 0

    def take(self, count: int) -> bytes:
        if count < 0 or count > MAX_VALUE or count > len(self.data) - self.offset:
            raise CacheError("truncated or oversized cache value")
        start = self.offset
        self.offset += count
        return self.data[start:self.offset]

    def number(self, fmt: str):
        return struct.unpack(fmt, self.take(struct.calcsize(fmt)))[0]

    def read(self, depth: int = 0):
        self.values += 1
        if depth > 24 or self.values > MAX_ITEMS:
            raise CacheError("cache structure budget exceeded")
        tag = self.number(">B")
        if tag <= 0x7F:
            return tag
        if tag >= 0xE0:
            return tag - 256
        if tag == 0xC0:
            return None
        if tag in (0xC2, 0xC3):
            return tag == 0xC3
        numeric = {0xCA: ">f", 0xCB: ">d", 0xCC: ">B", 0xCD: ">H", 0xCE: ">I", 0xCF: ">Q",
                   0xD0: ">b", 0xD1: ">h", 0xD2: ">i", 0xD3: ">q"}
        if tag in numeric:
            return self.number(numeric[tag])
        if 0xA0 <= tag <= 0xBF or tag in (0xD9, 0xDA, 0xDB):
            size = tag - 0xA0 if tag < 0xC0 else self.number({0xD9: ">B", 0xDA: ">H", 0xDB: ">I"}[tag])
            try:
                return self.take(size).decode("utf-8", errors="strict")
            except UnicodeDecodeError as error:
                raise CacheError("invalid cache string") from error
        if tag in (0xC4, 0xC5, 0xC6):
            return self.take(self.number({0xC4: ">B", 0xC5: ">H", 0xC6: ">I"}[tag]))
        if 0x90 <= tag <= 0x9F or tag in (0xDC, 0xDD):
            size = tag - 0x90 if tag < 0xC0 else self.number(">H" if tag == 0xDC else ">I")
            if size > MAX_ITEMS:
                raise CacheError("cache array budget exceeded")
            return [self.read(depth + 1) for _ in range(size)]
        if 0x80 <= tag <= 0x8F or tag in (0xDE, 0xDF):
            size = tag - 0x80 if tag < 0xC0 else self.number(">H" if tag == 0xDE else ">I")
            if size > MAX_ITEMS:
                raise CacheError("cache map budget exceeded")
            return [(self.read(depth + 1), self.read(depth + 1)) for _ in range(size)]
        raise CacheError(f"unsupported cache tag 0x{tag:02x}")


def shape(value):
    if isinstance(value, bytes):
        return {"binary_bytes": len(value), "sha256": hashlib.sha256(value).hexdigest(),
                "prefix": value[:16].hex()}
    if isinstance(value, str):
        return value[:400]
    if isinstance(value, list):
        return [shape(child) for child in value[:12]]
    if isinstance(value, tuple):
        return tuple(shape(child) for child in value)
    return value


def dxbc_stage(data: bytes) -> str:
    if len(data) < 32 or data[:4] != b"DXBC":
        raise CacheError("DXBC/DXIL container required; no decompression guess")
    version, total, count = struct.unpack_from("<III", data, 20)
    if version != 1 or total != len(data) or not 1 <= count <= 64 or 32 + 4 * count > total:
        raise CacheError("invalid DXBC header")
    extents = []
    stages = []
    for offset in struct.unpack_from(f"<{count}I", data, 32):
        if offset < 32 + 4 * count or offset > total - 8:
            raise CacheError("invalid DXBC chunk offset")
        size = struct.unpack_from("<I", data, offset + 4)[0]
        if size > total - offset - 8:
            raise CacheError("truncated DXBC chunk")
        extent = (offset, offset + 8 + size)
        if any(extent[0] < end and start < extent[1] for start, end in extents):
            raise CacheError("overlapping DXBC chunks")
        extents.append(extent)
        kind = data[offset:offset + 4]
        if kind in (b"SHDR", b"SHEX", b"DXIL"):
            if size < 8 or size % 4:
                raise CacheError("invalid shader-token chunk")
            token, words = struct.unpack_from("<II", data, offset + 8)
            major = (token >> 4) & 15
            if words * 4 != size or major != (6 if kind == b"DXIL" else 5) or token & 15 != 0 or token >> 16 not in (0, 1):
                raise CacheError("only exact SM5.0/SM6.0 pixel/vertex artifacts supported")
            if kind == b"DXIL":
                if size < 24 or data[offset + 16:offset + 20] != b"DXIL":
                    raise CacheError("invalid DXIL program header")
                bit_offset, bit_size = struct.unpack_from("<II", data, offset + 24)
                start = 8 + bit_offset
                if bit_offset < 16 or start > size or bit_size > size - start or bit_size < 4:
                    raise CacheError("invalid DXIL bitcode bounds")
                if data[offset + 8 + start:offset + 12 + start] != b"BC\xc0\xde":
                    raise CacheError("invalid DXIL bitcode magic")
            stages.append("Fragment" if token >> 16 == 0 else "Vertex")
    if len(stages) != 1:
        raise CacheError("missing/ambiguous shader stage")
    return stages[0]


def inventory(data: bytes, entry: str):
    if not entry.startswith("shaders/beamrt/") or not entry.endswith(".hlsl") or ".." in entry:
        raise CacheError("explicit BeamRT shader source entry required")
    reader = Reader(data)
    header = reader.read()
    if not isinstance(header, list) or len(header) != 1 or not isinstance(header[0], str):
        raise CacheError("unsupported cache header")
    matches = []
    records = 0
    while reader.offset < len(data):
        offset = reader.offset
        value = reader.read()
        records += 1
        if isinstance(value, list) and value and isinstance(value[0], str) and value[0].startswith(entry + " "):
            if len(value) != 3 or value[0] != value[1] or not isinstance(value[2], bytes):
                raise CacheError("unsupported shader cache record")
            stage = dxbc_stage(value[2])
            if not value[0].startswith(entry + " " + stage + " "):
                raise CacheError("cache key disagrees with bytecode stage")
            matches.append((offset, stage, value[0], value[2]))
    return header[0], records, matches


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cache", type=Path)
    parser.add_argument("--entry", default="shaders/beamrt/beamrtGITraceP_v082.hlsl")
    parser.add_argument("--extract-to", type=Path, help="new ignored artifact directory; never the original cache")
    args = parser.parse_args()
    if args.cache.stat().st_size > MAX_CACHE:
        raise CacheError("cache file budget exceeded")
    with args.cache.open("rb") as cache_file:
        data = cache_file.read(MAX_CACHE + 1)
    build, records, matches = inventory(data, args.entry)
    digest = hashlib.sha256(data).hexdigest()
    manifest = {"build": build, "cache_sha256": digest, "source_entry": args.entry,
                "executing_pass_verified": False, "root_layout_verified": False, "stages": []}
    print(json.dumps({"build": build, "cache_sha256": digest}))
    for offset, stage, key, binary in matches:
        record = {"offset": offset, "stage": stage, "key": key, "binary": shape(binary)}
        manifest["stages"].append(record)
        print(json.dumps(record))
    if args.extract_to:
        if sorted(stage for _, stage, _, _ in matches) != ["Fragment", "Vertex"]:
            raise CacheError("extraction requires exactly one pixel and one vertex permutation")
        target = args.extract_to.resolve()
        root = Path(__file__).resolve().parents[1] / ".beamrt-validation"
        if not target.is_relative_to(root.resolve()):
            raise CacheError("extraction must stay in the workspace's ignored validation directory")
        target.mkdir(parents=True, exist_ok=False)
        for _, stage, _, binary in matches:
            with (target / ("target.ps.cso" if stage == "Fragment" else "target.vs.cso")).open("xb") as output:
                output.write(binary)
        with (target / "manifest.json").open("x", encoding="utf-8") as output:
            json.dump(manifest, output, indent=2)
    print(json.dumps({"records": records, "bytes": len(data), "read_only": True,
                      "executing_pass_verified": False}))


if __name__ == "__main__":
    main()
