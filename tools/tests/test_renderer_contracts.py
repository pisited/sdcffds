"""Repository invariants for BeamRT's opt-in rendering experiments.

Lua sources are compiled, never executed, with Lua 5.1 and LuaJIT. The GI
binding check validates the complete literal sampler list. Neither proves
BeamNG shader compilation or GPU execution.
"""
from pathlib import Path
import re
import unittest
from lupa.lua51 import LuaRuntime as Lua51Runtime
from lupa.luajit21 import LuaRuntime as LuaJITRuntime

ROOT = Path(__file__).resolve().parents[2]
MAIN = ROOT / "lua/ge/extensions/beamrt/main.lua"
LUA_RUNTIMES = (("Lua 5.1", Lua51Runtime), ("LuaJIT", LuaJITRuntime))
GI_INPUTS = (
    "prepassTex", "prepassDepthTex", "backBufferTex",
    "lightInfoTex", "auxiliaryTex", "meshDataTex",
)

# Keep comments and quoted/long strings atomic so commented-out or stringified
# calls cannot satisfy the binding check. Other tokens need no Lua evaluation.
LUA_TOKEN = re.compile(
    r"--\[(?P<comment_eq>=*)\[.*?\](?P=comment_eq)\]"
    r"|--[^\r\n]*"
    r'|"(?:\\.|[^"\\])*"'
    r"|'(?:\\.|[^'\\])*'"
    r"|\[(?P<string_eq>=*)\[.*?\](?P=string_eq)\]"
    r"|[A-Za-z_]\w*|\S",
    re.S,
)


def compile_lua(source, runtime_type):
    runtime = runtime_type(unpack_returned_tuples=True)
    # Calling loadstring only compiles; never call the returned module chunk.
    compile_only = runtime.eval(
        "function(source) local chunk, err = loadstring(source, '@main.lua'); "
        "return chunk ~= nil, err end"
    )
    return compile_only(source)


def mesh_gi_inputs(source):
    tokens = [match.group() for match in LUA_TOKEN.finditer(source)
              if not match.group().startswith('--')]
    prefix = ["createShader", "(", "M", ".", "sharedMeshGI", ".", "shaderName", ",",
              "M", ".", "sharedMeshGI", ".", "shaderEntry", ",", "{"]
    starts = [index + len(prefix) for index in range(len(tokens))
              if tokens[index:index + len(prefix)] == prefix]
    if len(starts) != 1:
        raise AssertionError("Expected exactly one literal shared-mesh GI shader binding")
    index = starts[0]
    inputs = []
    while index < len(tokens) and tokens[index] != "}":
        token = tokens[index]
        # Sampler names are plain string literals, not dynamic expressions or
        # keyed table entries. Reject unfamiliar layouts rather than ignoring them.
        if not re.fullmatch(r'''["'][A-Za-z_]\w*["']''', token) or token[0] != token[-1]:
            raise AssertionError("GI samplers must be a literal array of names")
        inputs.append(token[1:-1])
        index += 1
        if index < len(tokens) and tokens[index] == ",":
            index += 1
        elif index >= len(tokens) or tokens[index] != "}":
            raise AssertionError("Unexpected expression in GI sampler list")
    if tokens[index:index + 2] != ["}", ")"]:
        raise AssertionError("Incomplete or nonliteral GI shader binding")
    return tuple(inputs)


def require_mesh_gi_inputs(source):
    inputs = mesh_gi_inputs(source)
    if inputs != GI_INPUTS:
        raise AssertionError(f"Expected exactly six ordered GI inputs {GI_INPUTS}; got {inputs}")


class RendererContracts(unittest.TestCase):
    def test_main_lua_local_declaration_budget(self):
        source = MAIN.read_text(encoding="utf-8")
        for name, runtime in LUA_RUNTIMES:
            with self.subTest(runtime=name):
                compiled, error = compile_lua(source, runtime)
                self.assertTrue(compiled, f"{name} rejected main.lua: {error}")

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
        require_mesh_gi_inputs(main)
        self.assertIn("meshSceneInputs", main)

    def test_uncertain_geometry_cannot_prove_opaque_shadow(self):
        fragment = (ROOT / "lua/ge/extensions/beamrt/meshMaterialPolicy.lua").read_text(encoding="utf-8")
        self.assertIn("alpha-test texture required; native fallback", fragment)
        self.assertIn("transparency requires transmission; native fallback", fragment)
        self.assertIn("incomplete native opacity declaration", fragment)
        self.assertIn("unsupported native class", fragment)


class GuardrailRegressions(unittest.TestCase):
    def binding(self, inputs):
        return "createShader(M.sharedMeshGI.shaderName,M.sharedMeshGI.shaderEntry,{" + inputs + "})"

    def test_compilers_reject_multiple_locals_on_one_line(self):
        source = "local " + ",".join(f"v{i}" for i in range(201))
        for name, runtime in LUA_RUNTIMES:
            with self.subTest(runtime=name):
                compiled, error = compile_lua(source, runtime)
                self.assertFalse(compiled)
                self.assertIn("local", error)

    def test_compilers_accept_boundary_and_scoped_locals_without_execution(self):
        boundary = "local " + ",".join(f"v{i}" for i in range(200))
        for name, runtime in LUA_RUNTIMES:
            for source in (boundary, "do " + boundary + " end\ndo " + boundary + " end",
                           "error('module chunk must not be executed')"):
                with self.subTest(runtime=name, source=source[:40]):
                    compiled, error = compile_lua(source, runtime)
                    self.assertTrue(compiled, error)

    def test_compilers_reject_nested_function_local_overflow(self):
        source = "local function nested() local " + ",".join(f"v{i}" for i in range(201)) + " end"
        for name, runtime in LUA_RUNTIMES:
            with self.subTest(runtime=name):
                self.assertFalse(compile_lua(source, runtime)[0])

    def test_sampler_guard_rejects_seventh_missing_duplicate_and_reordered_inputs(self):
        for inputs in (GI_INPUTS + ("extraTex",), GI_INPUTS[:-1],
                       GI_INPUTS[:-1] + (GI_INPUTS[0],), tuple(reversed(GI_INPUTS))):
            with self.subTest(inputs=inputs), self.assertRaises(AssertionError):
                require_mesh_gi_inputs(self.binding(",".join(repr(name) for name in inputs)))

    def test_sampler_guard_accepts_formatting_comments_and_trailing_comma(self):
        inputs = ", -- line comment\n".join(repr(name) for name in GI_INPUTS) + ","
        require_mesh_gi_inputs(self.binding("--[=[ ignored } fake call ]=]\n" + inputs))

    def test_sampler_guard_ignores_commented_or_stringified_calls(self):
        binding = self.binding(",".join(repr(name) for name in GI_INPUTS))
        for decoy in ("--" + binding, "--[=[" + binding + "]=]",
                      "local example = [=[" + binding + "]=]", "local example = " + repr(binding)):
            with self.subTest(decoy=decoy), self.assertRaises(AssertionError):
                require_mesh_gi_inputs(decoy)
            require_mesh_gi_inputs(decoy + "\n" + binding)

    def test_sampler_guard_rejects_duplicate_calls_and_dynamic_or_keyed_lists(self):
        binding = self.binding(",".join(repr(name) for name in GI_INPUTS))
        for source in (binding + "\n" + binding, self.binding("unverifiedSamplers"),
                       self.binding("[1]='prepassTex'"), self.binding("'prepassTex' .. suffix")):
            with self.subTest(source=source), self.assertRaises(AssertionError):
                require_mesh_gi_inputs(source)

if __name__ == "__main__":
    unittest.main(verbosity=2)
