"""Automatic CPU-receipt acknowledgement joins, with no game or process launch.

The clock and publisher are injected. Receipt bytes are deliberately synthetic;
these cases test orchestration rather than replacing the pinned native validator.
The existing acknowledgement suite exercises that decoder against copied offline
fixtures. An explicit expected PID represents the caller's retained-child input,
never evidence inferred here from receipt bytes or process-name discovery.
"""
import ast
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/receipt_handoff.py"
TOKEN = "0123456789abcdef0123456789abcdef"
PID = 12345
SIZES = (("", 1144), (".resources-start.bin", 392), (".resources.bin", 32768))


def load_helper():
    spec = importlib.util.spec_from_file_location("beamrt_unattended_handoff_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeClock:
    def __init__(self):
        self.value = 0.0
        self.sleeps = []
        self.after_sleep = None

    def now(self):
        return self.value

    def sleep(self, seconds):
        if not math.isfinite(seconds) or not 0 < seconds <= 1:
            raise AssertionError("handoff requested an invalid or unbounded poll")
        self.sleeps.append(seconds)
        self.value += seconds
        if len(self.sleeps) > 100:
            raise AssertionError("bounded handoff failed to stop")
        if self.after_sleep:
            self.after_sleep(len(self.sleeps))


class ReceiptHandoffContracts(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-handoff-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.decoder = self.directory / "receipt_decoder.exe"
        self.decoder.write_bytes(b"synthetic decoder path; never executed")
        self.record = self.directory / "recorded-draw.bin"
        self.clock = FakeClock()
        self.calls = []
        self.events = []
        self.context = {"token": TOKEN, "expectedPid": PID}
        self.approval = {"token": TOKEN, "scope": "beamrt-unattended-observation-v1", "allow": True}
        self.ready = {"token": TOKEN, "expectedPid": PID, "kind": "cpu_receipt_ready",
                      "resourceABI": 7, "drawABI": 5, "profile": 2, "mode": 1,
                      "cbvProbeBytes": 0, "record": "recorded-draw.bin"}
        self.ack = {"token": TOKEN, "expectedPid": PID, "kind": "receipt_validated",
                    "resourceABI": 7, "profile": 2, "mode": 1, "cbvProbeBytes": 0,
                    "digest": "a" * 64}
        self.write_json("process-context.json", self.context)
        self.write_json("launch-approval.json", self.approval)
        self.write_json("receipt-ready.json", self.ready)
        self.write_bundle()

    def write_json(self, leaf, value):
        (self.directory / leaf).write_text(json.dumps(value), encoding="utf-8")

    def write_bundle(self):
        for ordinal, (suffix, size) in enumerate(SIZES):
            Path(str(self.record) + suffix).write_bytes(bytes([ordinal + 1]) * size)

    def publisher(self, decoder, record, expected_pid, token, output):
        self.events.append("publish")
        self.assertFalse((self.directory / "owner-stop.json").exists())
        self.assertFalse((self.directory / "owned-exit.json").exists())
        self.assertEqual(Path(output), self.directory / "driver-ack.json")
        self.calls.append((Path(decoder), Path(record), expected_pid, token, Path(output)))
        Path(output).write_text(json.dumps(self.ack), encoding="utf-8")
        self.events.append("ack-written")
        return dict(self.ack)

    def run_handoff(self, **overrides):
        arguments = {"run_dir": self.directory, "expected_pid": PID, "token": TOKEN,
                     "decoder": self.decoder, "timeout_seconds": 0.3, "poll_seconds": 0.05,
                     "clock": self.clock.now, "sleep": self.clock.sleep,
                     "publisher": self.publisher}
        arguments.update(overrides)
        return self.helper.wait_and_ack(**arguments)

    def refused(self, **overrides):
        with self.assertRaises((ValueError, OSError, TimeoutError)):
            self.run_handoff(**overrides)
        self.assertEqual(self.calls, [])
        self.assertFalse((self.directory / "driver-ack.json").exists())
        self.assertFalse((self.directory / "owner-stop.json").exists())

    def test_import_is_inert_and_does_not_read_context_publish_or_launch(self):
        with patch.object(Path, "open", side_effect=AssertionError("import read context")), \
                patch.object(subprocess, "run", side_effect=AssertionError("import launched subprocess")):
            module = load_helper()
        self.assertTrue(callable(module.wait_and_ack))

    def test_complete_ready_uses_explicit_identity_and_fixed_record_once(self):
        before = {path.name: path.read_bytes() for path in self.directory.iterdir()}
        with patch.object(subprocess, "run", side_effect=AssertionError("coordinator bypassed publisher")):
            result = self.run_handoff()
        self.assertEqual(result, self.ack)
        self.assertEqual(self.calls, [(self.decoder, self.record, PID, TOKEN, self.directory / "driver-ack.json")])
        self.assertEqual(self.events, ["publish", "ack-written"])
        for name, image in before.items():
            self.assertEqual((self.directory / name).read_bytes(), image)
        self.assertEqual(set(path.name for path in self.directory.iterdir()), set(before) | {"driver-ack.json"})
        self.assertEqual(self.clock.sleeps, [])

    def test_default_path_lazily_delegates_to_existing_physical_pinned_publisher(self):
        module = SimpleNamespace(publish_ack=self.publisher)
        loaded = []
        spec = SimpleNamespace(loader=SimpleNamespace(exec_module=lambda item: loaded.append(item)))
        with patch.object(self.helper.importlib.util, "spec_from_file_location", return_value=spec) as locate, \
                patch.object(self.helper.importlib.util, "module_from_spec", return_value=module):
            result = self.run_handoff(publisher=None)
        self.assertEqual(result, self.ack)
        self.assertEqual(loaded, [module])
        self.assertEqual(locate.call_args.args[1], SOURCE.with_name("receipt_ack.py"))
        self.assertEqual(len(self.calls), 1)

    def test_expected_pid_must_be_explicit_uint32_not_read_from_ready(self):
        for value in (None, False, True, 0, -1, 4294967296, 1.5, "12345"):
            with self.subTest(value=value): self.refused(expected_pid=value)

    def test_explicit_token_is_exact_lowercase_hex(self):
        for value in (None, 1, "", "a" * 31, "a" * 33, "A" * 32, "g" * 32, TOKEN + "\n"):
            with self.subTest(value=value): self.refused(token=value)

    def test_invalid_deadlines_and_poll_intervals_refuse_before_publication(self):
        for key in ("timeout_seconds", "poll_seconds"):
            for value in (None, False, True, 0, -1, float("nan"), float("inf"), "1"):
                with self.subTest(field=key, value=value): self.refused(**{key: value})

    def test_absent_ready_waits_only_until_bounded_deadline(self):
        (self.directory / "receipt-ready.json").unlink()
        self.refused()
        self.assertGreater(len(self.clock.sleeps), 0)
        self.assertLessEqual(self.clock.value, 0.35)

    def test_ready_and_bundle_can_arrive_after_initial_poll_without_inferred_identity(self):
        (self.directory / "receipt-ready.json").unlink()
        for suffix, _size in SIZES: Path(str(self.record) + suffix).unlink()
        def arrive(ordinal):
            if ordinal == 1:
                self.write_bundle()
                self.write_json("receipt-ready.json", self.ready)
        self.clock.after_sleep = arrive
        self.assertEqual(self.run_handoff(), self.ack)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(len(self.clock.sleeps), 1)

    def test_each_missing_partial_or_oversized_bundle_never_reaches_publisher(self):
        for suffix, size in SIZES:
            path = Path(str(self.record) + suffix)
            original = path.read_bytes()
            for image in (None, b"", original[:-1], original + b"x"):
                with self.subTest(suffix=suffix, size=None if image is None else len(image)):
                    self.clock = FakeClock()
                    if image is None: path.unlink()
                    else: path.write_bytes(image)
                    self.refused()
                    self.assertEqual(self.clock.sleeps, [], "readable ready promised a closed complete bundle")
                    path.write_bytes(original)

    def test_windows_ready_write_sharing_violation_is_bounded_poll_not_success(self):
        original_read = self.helper._read
        locked = PermissionError("host still writing ready")
        locked.winerror = 32
        def read_once_locked(path):
            if Path(path).name == "receipt-ready.json" and not self.clock.sleeps:
                raise locked
            return original_read(path)
        with patch.object(self.helper, "_read", side_effect=read_once_locked):
            self.assertEqual(self.run_handoff(), self.ack)
        self.assertEqual(len(self.clock.sleeps), 1)
        self.assertEqual(len(self.calls), 1)

    def test_nonsharing_ready_read_failure_is_not_retried_as_missing(self):
        original_read = self.helper._read
        denied = PermissionError("access denied")
        denied.winerror = 5
        def denied_ready(path):
            if Path(path).name == "receipt-ready.json": raise denied
            return original_read(path)
        with patch.object(self.helper, "_read", side_effect=denied_ready):
            self.refused()
        self.assertEqual(self.clock.sleeps, [])

    def test_foreign_context_pid_or_token_cannot_be_replaced_by_matching_ready(self):
        for key, value in (("expectedPid", PID + 1), ("expectedPid", True), ("expectedPid", str(PID)),
                           ("token", "b" * 32), ("unexpected", 1)):
            changed = dict(self.context); changed[key] = value
            self.write_json("process-context.json", changed)
            with self.subTest(field=key, value=value): self.refused()
        self.write_json("process-context.json", self.context)

    def test_approval_requires_exact_true_scope_and_token_not_just_file_presence(self):
        for key, value in (("allow", False), ("allow", 1), ("allow", "true"),
                           ("scope", "other"), ("token", "b" * 32), ("unexpected", 1)):
            changed = dict(self.approval); changed[key] = value
            self.write_json("launch-approval.json", changed)
            with self.subTest(field=key, value=value): self.refused()
        self.write_json("launch-approval.json", self.approval)

    def test_ready_requires_every_exact_identity_configuration_and_record_field(self):
        mutants = {"token": "b" * 32, "expectedPid": PID + 1, "kind": "other",
                   "resourceABI": 6, "drawABI": 4, "profile": 1, "mode": 0,
                   "cbvProbeBytes": 4, "record": "other.bin"}
        for key, value in mutants.items():
            for remove in (False, True):
                changed = dict(self.ready)
                if remove: del changed[key]
                else: changed[key] = value
                self.write_json("receipt-ready.json", changed)
                with self.subTest(field=key, remove=remove): self.refused()
        changed = dict(self.ready); changed["extra"] = "untrusted"
        self.write_json("receipt-ready.json", changed); self.refused()

    def test_ready_integer_fields_do_not_accept_booleans_strings_or_floats(self):
        for key in ("expectedPid", "resourceABI", "drawABI", "profile", "mode", "cbvProbeBytes"):
            for value in (True, str(self.ready[key]), float(self.ready[key])):
                changed = dict(self.ready); changed[key] = value
                self.write_json("receipt-ready.json", changed)
                with self.subTest(field=key, value=value): self.refused()

    def test_record_leaf_cannot_escape_run_directory(self):
        for leaf in ("../recorded-draw.bin", "sub/recorded-draw.bin", "sub\\recorded-draw.bin",
                     str(self.record), "recorded-draw.bin:stream", "recorded-draw.bin\x00"):
            changed = dict(self.ready); changed["record"] = leaf
            self.write_json("receipt-ready.json", changed)
            with self.subTest(leaf=leaf): self.refused()

    def test_context_approval_and_ready_json_is_bounded_exact_unique_and_finite(self):
        for leaf in ("process-context.json", "launch-approval.json", "receipt-ready.json"):
            original = (self.directory / leaf).read_bytes()
            key = "token" if leaf != "launch-approval.json" else "allow"
            duplicate = original[:-1] + b',"' + key.encode() + b'":true}'
            for image in (b"", b"not json", b"\xff", b"[]", b"null", duplicate,
                          b'{"extra":NaN}', b'{"extra":1e9999}', b" " * 4097):
                (self.directory / leaf).write_bytes(image)
                with self.subTest(leaf=leaf, image=image[:40]): self.refused()
            (self.directory / leaf).write_bytes(original)

    def test_missing_context_or_approval_never_uses_receipt_identity_as_substitute(self):
        for leaf in ("process-context.json", "launch-approval.json"):
            path = self.directory / leaf; image = path.read_bytes(); path.unlink()
            with self.subTest(leaf=leaf): self.refused()
            path.write_bytes(image)

    def test_preexisting_ack_stop_or_exit_consumes_no_publisher_and_preserves_files(self):
        for leaf in ("driver-ack.json", "owner-stop.json", "owned-exit.json",
                     "driver-ack.json.pending", "owner-stop.json.pending", "owned-exit.json.pending"):
            path = self.directory / leaf; image = b"existing run output must survive"; path.write_bytes(image)
            with self.subTest(leaf=leaf), self.assertRaises((ValueError, OSError, TimeoutError)):
                self.run_handoff()
            self.assertEqual(self.calls, [])
            self.assertEqual(path.read_bytes(), image)
            path.unlink()

    def test_started_marker_and_engine_event_log_are_legitimate_before_ready(self):
        self.write_json("started.json", {"token": TOKEN})
        (self.directory / "unattended-events.jsonl").write_text('{"event":"gi_started"}\n', encoding="utf-8")
        self.assertEqual(self.run_handoff(), self.ack)
        self.assertEqual(len(self.calls), 1)

    def test_context_change_while_waiting_is_not_hidden_by_later_matching_ready(self):
        (self.directory / "receipt-ready.json").unlink()
        def replace_context(_ordinal):
            changed = dict(self.context); changed["expectedPid"] = PID + 1
            self.write_json("process-context.json", changed)
            self.write_json("receipt-ready.json", self.ready)
        self.clock.after_sleep = replace_context
        self.refused()

    def test_reparse_alias_to_run_directory_is_not_accepted_as_owned_physical_path(self):
        alias = self.directory / "alias"
        try:
            os.symlink(self.directory, alias, target_is_directory=True)
        except (OSError, NotImplementedError) as error:
            self.skipTest("symlink creation is unavailable in this environment: " + str(error))
        self.refused(run_dir=alias)

    def test_stop_or_exit_arriving_before_ready_prevents_late_publication(self):
        (self.directory / "receipt-ready.json").unlink()
        for leaf in ("owner-stop.json", "owned-exit.json"):
            self.clock = FakeClock()
            def stopped(_ordinal):
                self.write_json(leaf, {"token": TOKEN, "expectedPid": PID})
                self.write_json("receipt-ready.json", self.ready)
            self.clock.after_sleep = stopped
            with self.subTest(leaf=leaf), self.assertRaises((ValueError, OSError, TimeoutError)):
                self.run_handoff()
            self.assertEqual(self.calls, [])
            self.assertFalse((self.directory / "driver-ack.json").exists())
            (self.directory / leaf).unlink()
            (self.directory / "receipt-ready.json").unlink()

    def test_publisher_returned_ack_requires_exact_identity_configuration_and_digest(self):
        mutants = {"token": "b" * 32, "expectedPid": PID + 1, "kind": "host_refused",
                   "resourceABI": 6, "profile": 1, "mode": 0, "cbvProbeBytes": 4,
                   "digest": "A" * 64, "extra": True}
        for key, value in mutants.items():
            def invalid(*_args, **_kwargs):
                result = dict(self.ack); result[key] = value
                return result
            with self.subTest(field=key), self.assertRaises((ValueError, OSError)):
                self.run_handoff(publisher=invalid)
        for key in self.ack:
            def missing(*_args, **_kwargs):
                result = dict(self.ack); del result[key]
                return result
            with self.subTest(missing=key), self.assertRaises((ValueError, OSError)):
                self.run_handoff(publisher=missing)
        for key in ("expectedPid", "resourceABI", "profile", "mode", "cbvProbeBytes"):
            def bool_field(*_args, **_kwargs):
                result = dict(self.ack); result[key] = True
                return result
            with self.subTest(boolean=key), self.assertRaises((ValueError, OSError)):
                self.run_handoff(publisher=bool_field)

    def test_publisher_refusal_or_timeout_does_not_synthesize_ack_or_stop(self):
        for error in (ValueError("native decoder refused"), subprocess.TimeoutExpired("decoder", 20),
                      PermissionError("publication denied")):
            def refuse(*_args, **_kwargs): raise error
            with self.subTest(error=type(error).__name__), self.assertRaises(type(error)):
                self.run_handoff(publisher=refuse)
            self.assertFalse((self.directory / "driver-ack.json").exists())
            self.assertFalse((self.directory / "owner-stop.json").exists())
            self.assertFalse((self.directory / "owned-exit.json").exists())

    def test_clock_regression_or_nonfinite_clock_fails_closed(self):
        (self.directory / "receipt-ready.json").unlink()
        for readings in ((1.0, 0.0), (0.0, float("nan")), (0.0, float("inf"))):
            values = iter(readings)
            with self.subTest(readings=readings):
                self.refused(clock=lambda: next(values, readings[-1]))

    def test_source_keeps_decoder_validation_boundary_and_no_process_control(self):
        source = SOURCE.read_text(encoding="utf-8")
        tree = ast.parse(source)
        calls = {node.func.id if isinstance(node.func, ast.Name) else node.func.attr
                 for node in ast.walk(tree) if isinstance(node, ast.Call)
                 and isinstance(node.func, (ast.Name, ast.Attribute))}
        for forbidden in ("Popen", "CreateProcess", "OpenProcess", "TerminateProcess",
                          "GetProcessById", "EnumProcesses", "kill", "system"):
            self.assertNotIn(forbidden, calls)
        publisher = (SOURCE.parent / "receipt_ack.py").read_text(encoding="utf-8")
        self.assertIn('DECODER_SHA256 = "0aac455d357fdb8414f95c92cb539f8154136e5b6a48fe49971f7525ef65f804"', publisher)


if __name__ == "__main__":
    unittest.main()
