"""Inert native/game argv plans, with generated Lua parsed by both real runtimes.

No test launches the generated commands, claims a run, or opens game inputs.
Mocked factories prove literal configuration handoff, not BeamNG queue order.
"""

from dataclasses import FrozenInstanceError
import importlib.util
import math
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

from lupa.lua51 import LuaRuntime as Lua51
from lupa.luajit21 import LuaRuntime as LuaJIT21


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/startup_plan.py"


def load_module():
    spec = importlib.util.spec_from_file_location("beamrt_startup_plan_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    # Dataclasses require their defining module to be registered, as a normal
    # import is. This test loader does not rely on workspace package/search paths.
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def declarations(module):
    leaves = dict(module.LEAVES, vertex="gi.vs.cso", pixel="gi.ps.cso")
    files = {role: {"path": "C:/frozen/" + leaf, "sha256": "a" * 64}
             for role, leaf in leaves.items()}
    files["target"]["path"] = "E:/Games/BeamNG.drive/Bin64/BeamNG.drive.x64.exe"
    files["decoder"]["sha256"] = module.DECODER_SHA256
    return {"files": files, "run_directory": "C:/evidence/run-0123", "token": "0123456789abcdef" * 2,
            "limits": {"load_timeout": 300, "capture_timeout": 120, "overall_timeout": 480,
                       "stable_seconds": 2, "stable_frames": 8, "quit_grace": 10,
                       "shim_timeout": 30, "receipt_wait": 30}}


class StartupPlanContracts(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.args = declarations(self.module)

    def test_import_and_review_do_not_read_claim_execute_or_check_files(self):
        source = compile(SOURCE.read_text("utf-8"), str(SOURCE), "exec")
        with patch("builtins.open", side_effect=AssertionError("review opened a file")), \
                patch.object(Path, "open", side_effect=AssertionError("review opened a path")), \
                patch.object(Path, "stat", side_effect=AssertionError("review inspected a path")), \
                patch.object(os, "open", side_effect=AssertionError("review opened a descriptor")), \
                patch.object(os, "link", side_effect=AssertionError("review claimed a file")), \
                patch.object(subprocess, "Popen", side_effect=AssertionError("review launched")), \
                patch.object(subprocess, "run", side_effect=AssertionError("review executed")):
            exec(source, self.module.__dict__)
            plan = self.module.build_plan(**self.args)
        self.assertEqual(plan.host_argv[1], "--review")
        self.assertNotIn("--launch-reviewed", plan.host_argv)

    def test_output_is_immutable_and_not_backed_by_mutable_inputs(self):
        plan = self.module.build_plan(**self.args)
        before = plan.host_argv
        self.args["files"]["target"]["path"] = "E:/changed.exe"
        self.args["limits"]["load_timeout"] = 1
        self.assertEqual(plan.host_argv, before)
        self.assertIsInstance(plan.host_argv, tuple)
        self.assertIsInstance(plan.engine_argv, tuple)
        with self.assertRaises(FrozenInstanceError):
            plan.token = "f" * 32

    def test_exact_fixed_observation_mode_and_evidence_names(self):
        plan = self.module.build_plan(**self.args)
        argv = plan.host_argv
        for flag in ("--entry-rendezvous", "--observe-device-import", "--observe-gi-creation",
                     "--observe-gi-bindings", "--observe-gi-resources", "--resource-descriptors-only",
                     "--resource-interned-storage"):
            self.assertEqual(argv.count(flag), 1)
        for flag in ("--resource-compact-storage", "--resource-cbv-probe-bytes", "--launch-reviewed"):
            self.assertNotIn(flag, argv)
        self.assertEqual(argv[argv.index("--bindings-out") + 1], "C:\\evidence\\run-0123\\recorded-draw.bin")
        self.assertEqual(argv[argv.index("--workdir") + 1], "E:\\Games\\BeamNG.drive")
        self.assertEqual(argv[argv.index("--pipeline-root-out") + 1], "C:\\evidence\\run-0123\\root.bin")
        self.assertEqual(argv[argv.index("--owned-run-token") + 1], self.args["token"])
        self.assertEqual(argv[argv.index("--acknowledge-owned-force-close") + 1],
                         "exact-created-child-after-normal-quit")
        self.assertEqual(argv[argv.index("--acknowledge-native-insertion") + 1], "startup-observation-only")
        self.assertEqual(argv[argv.index("--pipeline-wait-seconds") + 1], "300")
        self.assertEqual(argv[argv.index("--bindings-wait-seconds") + 1], "120")
        self.assertEqual(argv[argv.index("--owned-overall-seconds") + 1], "480")
        self.assertEqual(argv[argv.index("--owned-normal-grace-seconds") + 1], "10")
        self.assertEqual(argv[argv.index("--owned-receipt-wait-seconds") + 1], "30")
        self.assertEqual(argv[argv.index("--") + 1:], plan.engine_argv)
        self.assertEqual(plan.engine_argv[:-1], ("-level", "west_coast_usa", "-beamrtObservationToken",
                                               self.args["token"], "-lua"))
        self.assertEqual(plan.engine_argv[-1], plan.lua_code)

    def test_file_role_schema_cannot_admit_arbitrary_arguments(self):
        for mutation in (lambda args: args["files"].pop("target"),
                         lambda args: args["files"].update(extra={"path": "C:/extra", "sha256": "a" * 64}),
                         lambda args: args["files"]["host"].update(arguments=["--launch-reviewed"]),
                         lambda args: args.update(files=[]),
                         lambda args: args["files"].update(host=[])):
            with self.subTest(mutation=mutation):
                args = declarations(self.module); mutation(args)
                with self.assertRaises(ValueError):
                    self.module.build_plan(**args)
        with self.assertRaises(TypeError):
            self.module.build_plan(**self.args, engine_arguments=["-lua", "quit()"])

    def test_hashes_and_roles_are_explicit_not_inferred_from_files(self):
        for digest in (None, True, "a" * 63, "A" * 64, "g" * 64, "a" * 64 + "\n"):
            args = declarations(self.module); args["files"]["host"]["sha256"] = digest
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                self.module.build_plan(**args)
        args = declarations(self.module); args["files"]["decoder"]["sha256"] = "b" * 64
        with self.assertRaises(ValueError):
            self.module.build_plan(**args)
        for role, leaf in self.module.LEAVES.items():
            args = declarations(self.module); args["files"][role]["path"] = "C:/frozen/other-" + leaf
            with self.subTest(role=role), self.assertRaises(ValueError):
                self.module.build_plan(**args)
        args = declarations(self.module)
        args["files"]["target"]["path"] = "E:/Games/BeamNG.drive/not-Bin64/BeamNG.drive.x64.exe"
        with self.assertRaisesRegex(ValueError, "inside Bin64"):
            self.module.build_plan(**args)

    def test_noncanonical_paths_and_control_injection_are_refused(self):
        bad = (None, "", "relative/path", "C:relative", "\\\\server\\share\\run", "\\\\?\\C:\\run",
               "C:/", "C:/a//b", "C:/a/../b", "C:/a/./b", "C:/NUL/b", "C:/com9.txt/b",
               "C:/a./b", "C:/a /b", 'C:/a"/b', "C:/a|b", "C:/a:b", "C:/a?b", "C:/a*b",
               "C:/a\nb", "C:/a\rb", "C:/a\tb", "C:/a\0b", "C:/a\x7fb", "C:/a\ud800b",
               "C:/a\x85b", "C:/a\u2028b", "C:/a\u2029b", "C:/a\u202eb")
        for path in bad:
            args = declarations(self.module); args["run_directory"] = path
            with self.subTest(path=repr(path)), self.assertRaises(ValueError):
                self.module.build_plan(**args)
        args = declarations(self.module); args["files"]["dll"]["path"] = "C:/雪/beamrt_startup_bootstrap.dll"
        with self.assertRaisesRegex(ValueError, "ASCII"):
            self.module.build_plan(**args)

    def test_run_directory_normalizes_only_slashes_and_one_trailing_separator(self):
        self.args["run_directory"] = "C:/evidence/run-0123/"
        plan = self.module.build_plan(**self.args)
        self.assertEqual(plan.run_directory, "C:\\evidence\\run-0123")

    def test_input_aliases_and_output_aliases_are_refused(self):
        args = declarations(self.module)
        args["files"]["pixel"] = dict(args["files"]["vertex"])
        with self.assertRaises(ValueError):
            self.module.build_plan(**args)
        # Fixed evidence leaves cannot be redirected through extra role keys.
        args = declarations(self.module)
        args["files"]["vertex"]["path"] = "C:/evidence/run-0123/recorded-draw.bin"
        with self.assertRaises(ValueError):
            self.module.build_plan(**args)

    def test_token_is_exact_lowercase_literal(self):
        for token in (None, True, "", "a" * 31, "a" * 33, "A" * 32, "g" * 32,
                      "a" * 32 + "\n", "';quit();--"):
            args = declarations(self.module); args["token"] = token
            with self.subTest(token=token), self.assertRaises(ValueError):
                self.module.build_plan(**args)

    def test_each_limit_is_explicit_finite_bounded_and_correctly_typed(self):
        for name, (low, high) in self.module.LIMITS.items():
            for value in (None, True, str(low), low - 0.01, high + 0.01, 10 ** 1000, math.nan, math.inf, -math.inf):
                args = declarations(self.module); args["limits"][name] = value
                with self.subTest(name=name, value=value), self.assertRaises(ValueError):
                    self.module.build_plan(**args)
            for value in (low, high):
                args = declarations(self.module); args["limits"][name] = value
                self.module.build_plan(**args)
            if name != "stable_seconds":
                args = declarations(self.module); args["limits"][name] = float(high)
                with self.subTest(name=name, float_integer=True), self.assertRaises(ValueError):
                    self.module.build_plan(**args)
        for mutation in (lambda limits: limits.pop("quit_grace"), lambda limits: limits.update(extra=1)):
            args = declarations(self.module); mutation(args["limits"])
            with self.assertRaises(ValueError):
                self.module.build_plan(**args)

    def test_ordinary_native_and_companion_paths_stay_below_max_path(self):
        args = declarations(self.module)
        args["run_directory"] = "C:/" + "a" * 230
        with self.assertRaisesRegex(ValueError, "path bound"):
            self.module.build_plan(**args)
        args = declarations(self.module)
        args["files"]["vertex"]["path"] = "C:/" + "a" * 253 + ".cso"
        with self.assertRaisesRegex(ValueError, "path bound"):
            self.module.build_plan(**args)

    def test_lua_and_windows_command_line_bounds_include_unicode_expansion(self):
        args = declarations(self.module)
        for role in ("early_shim", "bootstrap", "adapter", "controller"):
            args["files"][role]["path"] = "C:/" + "雪" * 290 + "/" + self.module.LEAVES[role]
        with self.assertRaisesRegex(ValueError, "Lua exceeds"):
            self.module.build_plan(**args)
        with patch.object(self.module.subprocess, "list2cmdline", return_value="😀" * 16384):
            with self.assertRaisesRegex(ValueError, "command-line bound"):
                self.module.build_plan(**self.args)
        self.module._command_bound(("a" * 32766,))
        with self.assertRaises(ValueError):
            self.module._command_bound(("a" * 32767,))


LUA_HARNESS = r"""
calls={}; captured={}; function count(name) calls[name]=(calls[name] or 0)+1 end
function dofile(path)
  count('dofile'); captured.path=path
  return {new=function(config,env)
    count('new'); captured.config=config; captured.env=env
    return {arm=function(token) count('arm'); captured.token=token; return true end}
  end}
end
function quit() count('quit'); error('unexpected quit') end
beamrt_main={start=function() count('GI'); error('unexpected GI') end}
extensions={load=function() count('load'); error('unexpected load') end}
io={open=function() count('io'); error('unexpected I/O') end}
os={execute=function() count('process'); error('unexpected process') end}
"""


class GeneratedLuaContracts:
    runtime = None

    def setUp(self):
        self.module = load_module()
        self.args = declarations(self.module)
        self.lua = self.runtime(unpack_returned_tuples=True)
        self.lua.execute(LUA_HARNESS)

    def check(self):
        plan = self.module.build_plan(**self.args)
        self.assertTrue(plan.lua_code.isascii())
        self.assertNotIn("\n", plan.lua_code)
        self.assertNotIn("\r", plan.lua_code)
        self.assertEqual(list(self.lua.globals().calls), [])  # building did not run Lua
        self.lua.execute(plan.lua_code)
        captured = self.lua.globals().captured
        self.assertEqual(captured.path, self.args["files"]["early_shim"]["path"].replace("\\", "/"))
        self.assertEqual(captured.token, self.args["token"])
        config = captured.config
        self.assertEqual(config.timeout, self.args["limits"]["shim_timeout"])
        self.assertEqual(config.bootstrapSourcePath, self.args["files"]["bootstrap"]["path"].replace("\\", "/"))
        self.assertEqual(config.bootstrap.runDirectory, self.args["run_directory"].replace("\\", "/").rstrip("/"))
        self.assertEqual(config.bootstrap.controllerSourcePath, self.args["files"]["controller"]["path"].replace("\\", "/"))
        self.assertEqual(config.bootstrap.adapterSourcePath, self.args["files"]["adapter"]["path"].replace("\\", "/"))
        controller = config.bootstrap.controller
        self.assertEqual(set(controller), {"token", "expectedLevel", "loadTimeout", "captureTimeout", "overallTimeout",
                                          "stableSeconds", "stableFrames", "quitGrace"})
        self.assertEqual(controller.token, self.args["token"])
        self.assertEqual(controller.expectedLevel, "west_coast_usa")
        for key, source in (("loadTimeout", "load_timeout"), ("captureTimeout", "capture_timeout"),
                            ("overallTimeout", "overall_timeout"), ("stableSeconds", "stable_seconds"),
                            ("stableFrames", "stable_frames"), ("quitGrace", "quit_grace")):
            self.assertEqual(controller[key], self.args["limits"][source])
        self.assertTrue(self.lua.eval("captured.env == _G"))
        self.assertEqual(dict(self.lua.globals().calls), {"dofile": 1, "new": 1, "arm": 1})
        return plan

    def test_generated_literal_config_uses_only_reviewed_factory_and_arm(self):
        self.check()

    def test_apostrophes_brackets_backslashes_spaces_and_unicode_remain_data(self):
        for role in ("early_shim", "bootstrap", "adapter", "controller"):
            self.args["files"][role]["path"] = "C:\\雪 O'Brien [=[x]=]\\" + self.module.LEAVES[role]
        self.args["run_directory"] = "C:\\evidence\\雪 O'Brien [=[x]=]"
        self.args["files"]["target"]["path"] = "E:\\遊戲 😀\\BeamNG.drive\\Bin64\\BeamNG.drive.x64.exe"
        plan = self.check()
        self.assertIn("遊戲 😀", plan.host_argv[plan.host_argv.index("--target") + 1])
        self.assertNotIn("雪", plan.lua_code)

    def test_fractional_stability_is_a_literal_number_not_lua_code(self):
        self.args["limits"]["stable_seconds"] = 0.1
        self.check()


class GeneratedLua51(GeneratedLuaContracts, unittest.TestCase):
    runtime = Lua51


class GeneratedLuaJIT21(GeneratedLuaContracts, unittest.TestCase):
    runtime = LuaJIT21


if __name__ == "__main__":
    unittest.main()
