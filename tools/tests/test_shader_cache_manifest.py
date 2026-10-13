"""Bounded synthetic cache tests. No game cache or compiler is needed."""
import importlib.util
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location("shader_cache", Path(__file__).resolve().parents[1] / "beamrt_shader_cache.py")
cache = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cache)
ENTRY = "shaders/beamrt/beamrtGITraceP_v082.hlsl"


def string(value):
    data = value.encode()
    return b"\xda" + struct.pack(">H", len(data)) + data


def container(kind, stage, model):
    token = (stage << 16) | model
    if kind == b"DXIL":
        program = struct.pack("<II", token, 7) + b"DXIL" + struct.pack("<III", 0x100, 16, 4) + b"BC\xc0\xde"
    else:
        program = struct.pack("<II", token, 2)
    total = 36 + 8 + len(program)
    return b"DXBC" + bytes(16) + struct.pack("<III", 1, total, 1) + struct.pack("<I", 36) + kind + struct.pack("<I", len(program)) + program


def record(stage, blob, entry=ENTRY):
    key = entry + " " + stage + " SHADER_STAGE_" + ("PS" if stage == "Fragment" else "VS") + " : 1"
    return b"\x93" + string(key) + string(key) + b"\xc6" + struct.pack(">I", len(blob)) + blob


class ShaderCacheManifest(unittest.TestCase):
    def test_named_entry_and_stage_from_dxil_bytes(self):
        data = b"\x91" + string("owned fixture build") + record("Vertex", container(b"DXIL", 1, 0x60)) + record("Fragment", container(b"DXIL", 0, 0x60))
        build, count, entries = cache.inventory(data, ENTRY)
        self.assertEqual(build, "owned fixture build")
        self.assertEqual(count, 2)
        self.assertEqual([row[1] for row in entries], ["Vertex", "Fragment"])

    def test_legacy_fixture_container_supported_without_assuming_live_sm5(self):
        self.assertEqual(cache.dxbc_stage(container(b"SHDR", 0, 0x50)), "Fragment")
        self.assertEqual(cache.dxbc_stage(container(b"SHEX", 1, 0x50)), "Vertex")

    def test_key_cannot_override_bytecode_stage(self):
        data = b"\x91" + string("build") + record("Vertex", container(b"DXIL", 0, 0x60))
        with self.assertRaises(cache.CacheError):
            cache.inventory(data, ENTRY)

    def test_nearby_source_name_does_not_match(self):
        data = b"\x91" + string("build") + record("Fragment", container(b"DXIL", 0, 0x60), ENTRY + ".other")
        self.assertEqual(cache.inventory(data, ENTRY)[2], [])

    def test_truncated_and_oversized_messagepack(self):
        for data in (b"\xc6\xff\xff\xff\xff", b"\xda\x00\x08abc", b"\xc1", b"\xdf\xff\xff\xff\xff"):
            with self.subTest(data=data), self.assertRaises(cache.CacheError):
                cache.Reader(data).read()

    def test_container_bounds_and_model_fail_closed(self):
        valid = container(b"DXIL", 0, 0x60)
        bad_offset = bytearray(valid)
        struct.pack_into("<I", bad_offset, 32, len(valid))
        bad_bits = bytearray(valid)
        struct.pack_into("<I", bad_bits, 60, 0xFFFFFFFF)
        for data in (valid[:-1], bytes(bad_offset), bytes(bad_bits), container(b"DXIL", 0, 0x66), container(b"SHEX", 5, 0x50)):
            with self.subTest(size=len(data)), self.assertRaises(cache.CacheError):
                cache.dxbc_stage(data)

    def test_unknown_or_non_beamrt_entry_refused(self):
        for entry in ("other.hlsl", "shaders/beamrt/../other.hlsl"):
            with self.assertRaises(cache.CacheError):
                cache.inventory(b"\x91" + string("build"), entry)

    def test_manifest_does_not_certify_execution_or_root_layout(self):
        source = Path(spec.origin).read_text()
        self.assertIn('"executing_pass_verified": False', source)
        self.assertIn('"root_layout_verified": False', source)
        self.assertIn('sorted(stage for _, stage, _, _ in matches)', source)
        self.assertIn('target.mkdir(parents=True, exist_ok=False)', source)
        self.assertIn('.open("xb")', source)


if __name__ == "__main__":
    unittest.main()
