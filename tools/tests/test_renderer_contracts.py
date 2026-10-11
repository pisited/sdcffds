"""Repository invariants for BeamRT's opt-in rendering experiments.

These are source-level guards, not BeamNG shader compilation or GPU tests.
The Lua mock tests exercise runtime behavior in the separate CI job.
"""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "lua/ge/extensions/beamrt/main.lua"

class RendererContracts(unittest.TestCase):
    def test_main_lua_local_declaration_budget(self):
        # Lua 5.1/LuaJIT compilation rejects functions with >200 locals.
        # The large top-level BeamRT module currently sits at the boundary.
        source = MAIN.read_text(encoding="utf-8")
        top_level = re.findall(r"^local\s+(?:(?:function)\s+)?[A-Za-z_]\w*", source, re.M)
        self.assertLessEqual(
            len(top_level), 200,
            "main.lua's top-level local declarations exceeded LuaJIT's 200-local "
            "budget. Put experimental state or helpers on the existing M table "
            "or in a separate module instead."
        )

    def test_native_lighting_experiments_default_off(self):
        main = MAIN.read_text(encoding="utf-8")
        sunlight = (ROOT / "lua/ge/extensions/beamrt/meshSunShadow.lua").read_text(encoding="utf-8")
        local = (ROOT / "lua/ge/extensions/beamrt/meshLocalLights.lua").read_text(encoding="utf-8")
        self.assertRegex(main, r"M\.sharedMeshGI\s*=\s*\{enabled=false")
        self.assertRegex(sunlight, r"local\s+active=false")
        self.assertRegex(local, r"local\s+active=false")
        self.assertIn("clustered lighting backend exposed", local)
        self.assertIn("function M.disable()", local)
        self.assertIn("function M.disable()", sunlight)

    def test_gi_mesh_shader_keeps_six_inputs(self):
        main = MAIN.read_text(encoding="utf-8")
        wrapper = (ROOT / "shaders/beamrt/beamrtGITraceP_v083.hlsl").read_text(encoding="utf-8")
        self.assertIn("#define BEAMRT_SHARED_MESH_GI 1", wrapper)
        self.assertIn('#include "beamrtGITraceP_v082.hlsl"', wrapper)
        self.assertRegex(main, r'createShader\(M\.sharedMeshGI\.shaderName,\s*M\.sharedMeshGI\.shaderEntry')
        self.assertIn('"prepassTex","prepassDepthTex","backBufferTex","lightInfoTex","auxiliaryTex","meshDataTex"', main)
        self.assertIn("meshSceneInputs", main)

    def test_uncertain_geometry_cannot_prove_opaque_shadow(self):
        fragment = (ROOT / "lua/ge/extensions/beamrt/meshMaterialPolicy.lua").read_text(encoding="utf-8")
        self.assertIn("alpha-test texture required; native fallback", fragment)
        self.assertIn("transparency requires transmission; native fallback", fragment)
        self.assertIn("incomplete native opacity declaration", fragment)
        self.assertIn("unsupported native class", fragment)

if __name__ == "__main__":
    unittest.main(verbosity=2)
