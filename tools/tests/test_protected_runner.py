"""Protected fixed-WARP runner contracts using no native process or game.

Real sibling helper source is hashed/compiled and real JSON joins are exercised.
Only input protection, host creation/clock and the native decoder publisher are
injected. Fake executable declarations are never opened or executed.
"""

from contextlib import ExitStack
import hashlib
import importlib.machinery
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCES = ROOT / "native/startup/unattended"
SOURCE = SOURCES / "protected_runner.py"
PID = 24680
DIGEST = "b" * 64


def load_module():
    spec = importlib.util.spec_from_file_location("beamrt_protected_runner_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def write_json(path, value):
    path.write_text(json.dumps(value, separators=(",", ":"), allow_nan=False), encoding="utf-8")


class FakeClock:
    def __init__(self):
        self.value = 0.0
        self.sleeps = []

    def __call__(self):
        return self.value

    def sleep(self, duration):
        if not 0 < duration <= 1:
            raise AssertionError("unbounded fake sleep")
        self.sleeps.append(duration)
        self.value += duration


@unittest.skipUnless(os.name == "nt", "Runner contracts require real Windows physical sibling/temp paths")
class ProtectedRunnerContracts(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-runner-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.candidate = {
            "schema": 1, "profile": self.module.FIXTURE_PROFILE,
            "files": {role: {"path": "C:/fixed-disposable/" + leaf, "sha256": digest}
                      for role, (leaf, digest) in self.module.FIXTURE_PINS.items()},
            "helpers": {leaf: {"path": str(SOURCES / leaf),
                                "sha256": hashlib.sha256((SOURCES / leaf).read_bytes()).hexdigest()}
                        for leaf in self.module.HELPERS},
            "run_directory": str(self.directory), "token": self.module.TOKEN,
            "limits": {"overall_timeout": 20, "quit_grace": 1, "receipt_wait": 5},
        }
        self.clock = FakeClock()
        self.events = []
        self.protections = []
        self.processes = []
        self.publisher_calls = []
        self.loaded_sources = []
        self.protection_open_error = None
        self.protection_claim_error = None
        self.corrupt_held_source = None
        self.publisher_error = None
        self.publisher_change = None
        self.context_change = None
        self.ready_change = None
        self.owner_change = None
        self.consumed_change = None
        self.process_failure = None
        self.never_ready = False
        self.never_exit = False
        self.exit_before_ready = False
        self.poll_error = None
        self.acknowledge = True
        self.exit_at_poll = 2
        self.owner_bytes = None
        self.context_bytes = None
        self.ack = None

    def protection_factory(self, manifest, directory):
        test = self

        class Protection:
            opened = False
            closed = False

            def open(self):
                test.events.append("protect-open")
                if test.protection_open_error:
                    raise test.protection_open_error
                self.opened = True

            def read_bytes(self, path, *, max_bytes):
                test.assertTrue(self.opened and not self.closed)
                test.assertIn(path, manifest)
                image = Path(path).read_bytes()
                test.assertLessEqual(len(image), max_bytes)
                test.assertEqual(hashlib.sha256(image).hexdigest(), manifest[path])
                test.events.append("read:" + Path(path).name)
                return image + b"\n" if Path(path).name == test.corrupt_held_source else image

            def claim_attempt(self, token, digest):
                test.assertTrue(self.opened and not self.closed)
                test.assertEqual(token, test.candidate["token"])
                test.assertEqual(digest, test.module.candidate_digest(test.candidate))
                test.events.append("claim")
                if test.protection_claim_error:
                    raise test.protection_claim_error
                claim = test.directory / "fake-runner-claim.json"
                with claim.open("xb") as stream:
                    stream.write(b"fixture claim only")

            def close(self):
                test.events.append("protect-close")
                self.closed = True

        self.assertEqual(directory, str(self.directory))
        self.assertEqual(len(manifest), len(self.module.HELPERS) + len(self.module.FIXTURE_PINS))
        instance = Protection()
        self.protections.append(instance)
        return instance

    def owner(self):
        value = {field: False for field in self.module.OWNER_BOOL_FIELDS}
        value.update({field: 0 for field in self.module.OWNER_NUMBER_FIELDS})
        value.update({"token": self.candidate["token"], "expectedPid": PID,
                 "processExitVerified": True, "normalRequested": not self.acknowledge,
                 "forceAttempted": False, "exitCode": 0 if self.acknowledge else 98,
                 "coreResult": 0 if self.acknowledge else 17, "observationError": 0,
                 "resumeAttempted": True, "resumed": True})
        if self.owner_change:
            self.owner_change(value)
        return value

    def publish(self, decoder, record, expected_pid, token, output):
        self.assertTrue(self.protections[-1].opened and not self.protections[-1].closed)
        self.events.append("publish-ACK")
        self.publisher_calls.append((decoder, record, expected_pid, token, output))
        self.assertEqual(expected_pid, PID)
        self.assertEqual(token, self.candidate["token"])
        self.assertEqual(record, self.directory / "recorded-draw.bin")
        self.assertEqual(output, self.directory / "driver-ack.json")
        if self.publisher_error:
            raise self.publisher_error
        self.ack = {"token": token, "kind": "receipt_validated", "expectedPid": expected_pid,
                    "resourceABI": 7, "profile": 2, "mode": 1, "cbvProbeBytes": 0, "digest": DIGEST}
        if self.publisher_change:
            self.publisher_change(self.ack)
        write_json(output, self.ack)
        return self.ack

    def process_factory(self, argv, **kwargs):
        test = self
        self.assertTrue(self.protections[-1].opened and not self.protections[-1].closed)
        self.events.append("create-host")
        if self.process_failure:
            raise self.process_failure
        self.assertIs(kwargs["shell"], False)
        self.assertIs(kwargs["close_fds"], True)
        self.assertEqual(kwargs["stderr"], subprocess.STDOUT)
        self.assertEqual(kwargs["cwd"], "C:/fixed-disposable")
        self.assertEqual(Path(argv[0]).name, "beamrt_startup_host.exe")
        self.assertIn("--launch-reviewed", argv)
        self.assertIn("--device-backend", argv)
        self.assertEqual(argv[argv.index("--device-backend") + 1], "warp")
        self.assertEqual(argv[argv.index("--binding-case") + 1], "resource-interned")
        self.assertNotIn("BeamNG.drive.x64.exe", " ".join(argv))
        self.assertNotIn("--resource-cbv-probe-bytes", argv)
        self.assertIn("--resource-interned-storage", argv)
        self.assertFalse(kwargs["stdout"].closed)
        self.assertEqual(kwargs["creationflags"], getattr(subprocess, "CREATE_NO_WINDOW", 0))

        if not self.never_ready and not self.exit_before_ready:
            context = {"token": self.candidate["token"], "expectedPid": PID}
            if self.context_change:
                self.context_change(context)
            if self.context_bytes is None:
                write_json(self.directory / "process-context.json", context)
            else:
                (self.directory / "process-context.json").write_bytes(self.context_bytes)
            write_json(self.directory / "launch-approval.json", {"token": self.candidate["token"],
                       "scope": "beamrt-unattended-observation-v1", "allow": True})
            ready = {"token": self.candidate["token"], "expectedPid": PID, "kind": "cpu_receipt_ready",
                     "resourceABI": 7, "drawABI": 5, "profile": 2, "mode": 1,
                     "cbvProbeBytes": 0, "record": "recorded-draw.bin"}
            if self.ready_change:
                self.ready_change(ready)
            write_json(self.directory / "receipt-ready.json", ready)
            for suffix, size in (("", 1144), (".resources-start.bin", 392), (".resources.bin", 32768)):
                Path(str(self.directory / "recorded-draw.bin") + suffix).write_bytes(b"\0" * size)

        class Process:
            polls = 0
            exited = False

            def poll(self):
                test.assertTrue(test.protections[-1].opened and not test.protections[-1].closed)
                test.events.append("host-poll")
                self.polls += 1
                if test.poll_error:
                    raise test.poll_error
                if test.never_exit:
                    return None
                if self.polls < test.exit_at_poll and not test.exit_before_ready:
                    return None
                if not self.exited:
                    self.exited = True
                    test.events.append("host-exit")
                    if test.owner_bytes is None:
                        write_json(test.directory / "owned-exit.json", test.owner())
                    else:
                        (test.directory / "owned-exit.json").write_bytes(test.owner_bytes)
                    if test.ack is not None:
                        consumed = {"token": test.candidate["token"], "expectedPid": PID,
                                    "kind": "fixture_ack_consumed", "digest": test.ack["digest"]}
                        if test.consumed_change:
                            test.consumed_change(consumed)
                        write_json(test.directory / "fixture-ack-consumed.json", consumed)
                return 0 if test.acknowledge else 17

            def wait(self, *args, **kwargs):
                raise AssertionError("runner must not wait unbounded on fake host")

            def kill(self):
                raise AssertionError("runner must never kill the host")

            def terminate(self):
                raise AssertionError("runner must never terminate the host")

        process = Process()
        self.processes.append(process)
        return process

    def run_fixture(self, **overrides):
        arguments = {"candidate": self.candidate, "expected_digest": self.module.candidate_digest(self.candidate),
                     "acknowledge": self.acknowledge, "protector_factory": self.protection_factory,
                     "process_factory": self.process_factory, "clock": self.clock, "sleep": self.clock.sleep}
        arguments.update(overrides)
        original_loader = self.module._load_source

        def checked_loader(entry, **kwargs):
            loaded = original_loader(entry, **kwargs)
            self.loaded_sources.append(Path(entry["path"]).name)
            if Path(entry["path"]).name == "receipt_ack.py":
                loaded.publish_ack = self.publish
            if Path(entry["path"]).name == "receipt_handoff.py":
                loaded._publish = lambda *_args, **_kwargs: self.fail("lazy unprotected publisher import")
            return loaded

        with patch.object(self.module, "_load_source", side_effect=checked_loader), \
                patch.object(subprocess, "Popen", side_effect=AssertionError("real process creation forbidden")), \
                patch.object(subprocess, "run", side_effect=AssertionError("real decoder execution forbidden")), \
                patch.object(importlib.util, "spec_from_file_location", side_effect=AssertionError("source loader used importlib cache")):
            return self.module.execute_fixture(**arguments)

    def test_review_is_inert_and_reports_game_execution_unavailable(self):
        with patch.object(subprocess, "Popen", side_effect=AssertionError("review launched")), \
                patch.object(os, "open", side_effect=AssertionError("review claimed a directory")), \
                patch.object(self.module, "_new_json", side_effect=AssertionError("review wrote a file")):
            review = self.module.review_candidate(self.candidate)
        self.assertFalse(review["gameExecutionAvailable"])
        self.assertFalse(review["outerChildFailsafeAvailable"])
        self.assertEqual(review["candidateSHA256"], self.module.candidate_digest(self.candidate))
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_success_keeps_input_protection_until_retained_host_exits(self):
        result = self.run_fixture()
        self.assertEqual(result["status"], "fixture_pass")
        self.assertTrue(result["hostExitVerified"])
        self.assertTrue(result["nativeReportedChildExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertFalse(result["outerChildFailsafeAvailable"])
        self.assertFalse(result["gameExecutionAvailable"])
        self.assertTrue(result["ackValidated"])
        self.assertTrue(result["fixtureAckConsumed"])
        self.assertEqual(result["hostExitCode"], 0)
        self.assertEqual(len(self.publisher_calls), 1)
        self.assertEqual(len(self.processes), 1)
        self.assertEqual(self.events[-1], "protect-close")
        self.assertLess(self.events.index("protect-open"), self.events.index("claim"))
        self.assertLess(self.events.index("claim"), self.events.index("create-host"))
        self.assertLess(self.events.index("publish-ACK"), self.events.index("host-exit"))
        self.assertLess(self.events.index("host-exit"), self.events.index("protect-close"))
        self.assertIn("read:receipt_ack.py", self.events)
        self.assertIn("read:receipt_handoff.py", self.events)
        self.assertTrue(self.protections[0].closed)
        self.assertEqual(json.loads((self.directory / "runner-result.json").read_text("utf-8")), result)

    def test_no_ack_mode_reports_expected_native_normal_stop_without_claiming_consumption(self):
        self.acknowledge = False
        result = self.run_fixture()
        self.assertEqual(result["status"], "fixture_pass")
        self.assertFalse(result["ackValidated"])
        self.assertFalse(result["fixtureAckConsumed"])
        self.assertEqual(self.publisher_calls, [])
        self.assertEqual(result["hostExitCode"], 17)
        self.assertEqual(result["nativeChildExitCode"], 98)
        self.assertFalse(result["independentChildExitVerified"])

    def test_candidate_digest_ack_type_and_profile_refuse_before_claim_or_process(self):
        for digest in (None, "a" * 64, True):
            with self.subTest(digest=digest), self.assertRaises(ValueError):
                self.run_fixture(expected_digest=digest)
        for policy in (None, 1, "true"):
            with self.subTest(policy=policy), self.assertRaises(ValueError):
                self.run_fixture(acknowledge=policy)
        self.candidate["profile"] = "unknown-profile"
        with self.assertRaises(ValueError):
            self.run_fixture()
        self.assertEqual(self.protections, [])
        self.assertEqual(self.processes, [])
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_fixture_artifact_hash_or_configuration_cannot_be_retargeted(self):
        for role in self.module.FIXTURE_PINS:
            original = self.candidate["files"][role]["sha256"]
            self.candidate["files"][role]["sha256"] = "f" * 64
            with self.subTest(role=role), self.assertRaises(ValueError):
                self.run_fixture()
            self.candidate["files"][role]["sha256"] = original
        self.candidate["limits"]["overall_timeout"] = 21
        with self.assertRaises(ValueError):
            self.run_fixture()
        self.assertEqual(self.processes, [])
        self.assertEqual(self.protections, [])

    def test_game_profile_can_be_reviewed_but_never_executed(self):
        self.candidate["profile"] = self.module.GAME_PROFILE
        self.candidate["files"] = {
            "host": {"path": "C:/game-review/beamrt_startup_host.exe", "sha256": "a" * 64},
            "target": {"path": "E:/BeamNG.drive/Bin64/BeamNG.drive.x64.exe", "sha256": "a" * 64},
            "dll": {"path": "C:/game-review/beamrt_startup_bootstrap.dll", "sha256": "a" * 64},
            "vertex": {"path": "C:/game-review/gi.vs.cso", "sha256": "a" * 64},
            "pixel": {"path": "C:/game-review/gi.ps.cso", "sha256": "a" * 64},
            "decoder": {"path": "C:/game-review/receipt_decoder.exe",
                        "sha256": self.module.FIXTURE_PINS["decoder"][1]},
        }
        for role, leaf in (("early_shim", "early_shim.lua"), ("bootstrap", "bootstrap.lua"),
                           ("adapter", "engine_adapter.lua"), ("controller", "controller.lua")):
            self.candidate["files"][role] = {"path": "C:/frozen-game-source/" + leaf, "sha256": "a" * 64}
        self.candidate["limits"] = {"load_timeout": 300, "capture_timeout": 120, "overall_timeout": 480,
            "stable_seconds": 2, "stable_frames": 8, "quit_grace": 10, "shim_timeout": 30, "receipt_wait": 30}
        review = self.module.review_candidate(self.candidate)
        self.assertIn("--review", review["hostArgv"])
        self.assertNotIn("--launch-reviewed", review["hostArgv"])
        self.assertEqual(review["engineArgv"][0:2], ("-level", "west_coast_usa"))
        self.assertFalse(review["gameExecutionAvailable"])
        with self.assertRaisesRegex(ValueError, "game execution disabled"):
            self.run_fixture()
        self.assertEqual(self.processes, [])
        self.assertEqual(self.protections, [])
        self.assertEqual(list(self.directory.iterdir()), [])

    def test_helper_paths_must_be_exact_runner_siblings(self):
        for leaf in self.module.HELPERS:
            original = self.candidate["helpers"][leaf]["path"]
            self.candidate["helpers"][leaf]["path"] = "C:/elsewhere/" + leaf
            with self.subTest(leaf=leaf), self.assertRaises(ValueError):
                self.run_fixture()
            self.candidate["helpers"][leaf]["path"] = original
        self.assertEqual(self.processes, [])

    def test_source_loader_rechecks_exact_held_bytes_and_ignores_cached_code(self):
        helper = self.directory / "inert_helper.py"
        image = b"SENTINEL = 'checked source bytes'\n"
        helper.write_bytes(image)
        digest = hashlib.sha256(image).hexdigest()
        cache = self.directory / "__pycache__"
        cache.mkdir()
        (cache / "inert_helper.cpython-310.pyc").write_bytes(b"not executable source")
        name = "beamrt_reviewed_inert_helper_" + digest[:16]
        poison = types.ModuleType(name); poison.SENTINEL = "cached poison"
        sys.modules[name] = poison
        self.addCleanup(sys.modules.pop, name, None)
        with patch.object(importlib.util, "spec_from_file_location", side_effect=AssertionError("used importlib")), \
                patch.object(importlib.machinery.SourceFileLoader, "get_code", side_effect=AssertionError("used cached bytecode")):
            loaded = self.module._load_source({"path": str(helper), "sha256": digest})
        self.assertEqual(loaded.SENTINEL, "checked source bytes")
        helper.write_bytes(b"SENTINEL = 'changed source'\n")
        with self.assertRaises(ValueError):
            self.module._load_source({"path": str(helper), "sha256": digest})

    def test_protection_open_failure_closes_without_claim_or_process(self):
        self.protection_open_error = ValueError("fixture input changed")
        with self.assertRaisesRegex(ValueError, "input changed"):
            self.run_fixture()
        self.assertEqual(self.events, ["protect-open", "protect-close"])
        self.assertEqual(self.processes, [])

    def test_claim_failure_or_replay_closes_without_process(self):
        self.protection_claim_error = FileExistsError("fixture stale claim")
        with self.assertRaises(FileExistsError):
            self.run_fixture()
        self.assertEqual(self.events[-1], "protect-close")
        self.assertEqual(self.processes, [])
        self.protection_claim_error = None
        (self.directory / "fake-runner-claim.json").write_bytes(b"already consumed")
        with self.assertRaises(FileExistsError):
            self.run_fixture()
        self.assertEqual(self.processes, [])

    def test_changed_held_helper_bytes_refuse_before_claim_and_process(self):
        self.corrupt_held_source = "receipt_ack.py"
        with self.assertRaisesRegex(ValueError, "helper source changed"):
            self.run_fixture()
        self.assertEqual(self.processes, [])
        self.assertNotIn("claim", self.events)
        self.assertEqual(self.events[-1], "protect-close")

    def test_invalid_initial_clock_refuses_before_creating_host(self):
        for sample in (True, None, "0", -1, 10 ** 1000, math.nan, math.inf, -math.inf):
            self.setUp()
            with self.subTest(sample=sample), self.assertRaises(ValueError):
                self.run_fixture(clock=lambda: sample)
            self.assertEqual(self.processes, [])
            self.assertEqual(self.events[-1], "protect-close")

    def test_process_creation_failure_still_releases_protection(self):
        self.process_failure = OSError("fixture creation refused")
        with self.assertRaisesRegex(OSError, "creation refused"):
            self.run_fixture()
        self.assertEqual(self.events[-1], "protect-close")
        self.assertTrue(self.protections[0].closed)
        self.assertEqual(self.processes, [])

    def test_failed_ack_waits_for_retained_host_but_does_not_mark_pass(self):
        self.publisher_error = ValueError("fixture decoder refused")
        result = self.run_fixture()
        self.assertEqual(result["status"], "fixture_failed")
        self.assertIn("decoder refused", result["reason"])
        self.assertTrue(result["hostExitVerified"])
        self.assertFalse(result["ackValidated"])
        self.assertFalse(result["fixtureAckConsumed"])
        self.assertLess(self.events.index("publish-ACK"), self.events.index("host-exit"))
        self.assertEqual(self.events[-1], "protect-close")

    def test_early_host_exit_never_implies_independent_child_cleanup(self):
        self.exit_before_ready = True
        result = self.run_fixture()
        self.assertNotEqual(result["status"], "fixture_pass")
        self.assertIn("exited before ready", result["reason"])
        self.assertTrue(result["hostExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.publisher_calls, [])
        self.assertEqual(self.events[-1], "protect-close")

    def test_nonexiting_host_hits_bounded_clock_without_wait_kill_or_pid_reopen(self):
        self.never_exit = True
        result = self.run_fixture()
        self.assertEqual(result["status"], "host_exit_unconfirmed")
        self.assertFalse(result["hostExitVerified"])
        self.assertFalse(result["nativeReportedChildExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertIsNone(result["hostExitCode"])
        self.assertGreaterEqual(self.clock.value, 40)
        self.assertLess(self.clock.value, 40.1)
        self.assertLess(len(self.clock.sleeps), 2100)
        self.assertEqual(self.events[-1], "protect-close")
        self.assertNotIn("host-exit", self.events)

    def test_no_ready_timeout_remains_bounded_while_host_is_retained(self):
        self.never_ready = self.never_exit = True
        result = self.run_fixture()
        self.assertEqual(result["status"], "host_exit_unconfirmed")
        self.assertEqual(self.publisher_calls, [])
        self.assertGreaterEqual(self.clock.value, 40)
        self.assertLess(self.clock.value, 40.1)
        self.assertFalse(result["independentChildExitVerified"])

    def test_retained_host_poll_failure_never_causes_wait_kill_or_pid_fallback(self):
        self.poll_error = OSError("fixture retained-host query failed")
        result = self.run_fixture()
        self.assertEqual(result["status"], "host_exit_unconfirmed")
        self.assertIn("query failed", result["reason"])
        self.assertFalse(result["hostExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.events[-1], "protect-close")
        self.assertLess(self.processes[0].polls, 10)

    def test_sleep_error_after_creation_returns_unknown_without_unbounded_cleanup(self):
        self.never_exit = True

        def failed_sleep(_seconds):
            raise OSError("fixture diagnostic sleep failed")

        result = self.run_fixture(sleep=failed_sleep)
        self.assertEqual(result["status"], "host_exit_unconfirmed")
        self.assertFalse(result["hostExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.events[-1], "protect-close")
        self.assertLess(self.processes[0].polls, 10)

    def test_regressing_clock_after_creation_returns_unknown_without_retry(self):
        self.never_exit = True
        samples = iter((1.0, 0.0))
        result = self.run_fixture(clock=lambda: next(samples))
        self.assertEqual(result["status"], "host_exit_unconfirmed")
        self.assertFalse(result["hostExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.events[-1], "protect-close")
        self.assertLess(self.processes[0].polls, 10)

    def test_clock_failure_cannot_be_hidden_by_host_exit_on_final_poll(self):
        samples = iter((1.0, 0.0))
        result = self.run_fixture(clock=lambda: next(samples))
        self.assertEqual(result["status"], "fixture_failed")
        self.assertTrue(result["hostExitVerified"])
        self.assertIn("clock", result["reason"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.events[-1], "protect-close")

    def test_sleep_failure_cannot_be_hidden_by_host_exit_on_final_poll(self):
        def failed_sleep(_seconds):
            raise OSError("fixture diagnostic sleep failed")

        result = self.run_fixture(sleep=failed_sleep)
        self.assertEqual(result["status"], "fixture_failed")
        self.assertTrue(result["hostExitVerified"])
        self.assertIn("sleep failed", result["reason"])
        self.assertFalse(result["independentChildExitVerified"])
        self.assertEqual(self.events[-1], "protect-close")

    def test_foreign_or_wrong_typed_context_cannot_reach_decoder(self):
        self.context_change = lambda value: value.update(expectedPid=True)
        result = self.run_fixture()
        self.assertNotEqual(result["status"], "fixture_pass")
        self.assertFalse(result["ackValidated"])
        self.assertEqual(self.publisher_calls, [])

    def test_ready_configuration_mismatch_refuses_before_decoder(self):
        self.ready_change = lambda value: value.update(profile=1)
        result = self.run_fixture()
        self.assertNotEqual(result["status"], "fixture_pass")
        self.assertFalse(result["ackValidated"])
        self.assertEqual(self.publisher_calls, [])

    def test_duplicate_context_keys_are_refused(self):
        self.context_bytes = ('{"token":"' + self.candidate["token"]
                              + '","expectedPid":1,"expectedPid":24680}').encode("ascii")
        result = self.run_fixture()
        self.assertNotEqual(result["status"], "fixture_pass")
        self.assertEqual(self.publisher_calls, [])

    def test_exit_report_boolean_fields_cannot_be_numbers(self):
        self.owner_change = lambda value: value.update(processExitVerified=1)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])
        self.assertFalse(result["independentChildExitVerified"])

    def test_exit_report_numeric_fields_cannot_be_boolean(self):
        self.owner_change = lambda value: value.update(exitCode=False)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")

    def test_exit_report_foreign_pid_is_not_joined(self):
        self.owner_change = lambda value: value.update(expectedPid=PID + 1)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_exit_report_missing_or_extra_fields_refuse(self):
        self.owner_change = lambda value: value.update(unrecognizedProof=True)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_exit_report_native_uint32_codes_cannot_overflow(self):
        self.owner_change = lambda value: value.update(exitCode=0x100000000)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_exit_report_exit_proof_cannot_contradict_observation_failure(self):
        self.owner_change = lambda value: value.update(observationError=5)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_exit_report_never_executed_state_cannot_describe_successful_fixture(self):
        self.owner_change = lambda value: value.update(neverExecutedCleanupAttempted=True)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_exit_report_duplicate_and_nonfinite_json_refuse(self):
        self.owner_bytes = b'{"expectedPid":24680,"exitCode":NaN,"exitCode":0}'
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertFalse(result["nativeReportedChildExitVerified"])

    def test_fixture_consumption_must_match_exact_ack_not_just_host_exit(self):
        self.consumed_change = lambda value: value.update(digest="c" * 64)
        result = self.run_fixture()
        self.assertEqual(result["status"], "native_child_state_unknown")
        self.assertTrue(result["ackValidated"])
        self.assertFalse(result["fixtureAckConsumed"])
        self.assertFalse(result["independentChildExitVerified"])

    def test_json_decoder_rejects_duplicates_nonfinite_overflow_and_wrong_roots(self):
        for image in (b'{"a":1,"a":2}', b'{"a":NaN}', b'{"a":Infinity}', b'{"a":1e999}',
                      b'[]', b'null', b'', b'"object"', b'{} ' + b' ' * 8192):
            with self.subTest(image=image[:40]), self.assertRaises(ValueError):
                self.module._decode(image, 8192)


if __name__ == "__main__":
    unittest.main()
