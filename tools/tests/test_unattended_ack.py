"""CPU receipt acknowledgement contracts; no game launch or OS ownership inference.

Pure cases replace subprocess.run, never execute fake bytes. The optional Windows
case executes only the hash-pinned read-only decoder against copies of historical
offline fixture receipts. Reading that fixture PID is NOT live process ownership.
"""
from contextlib import ExitStack
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/receipt_ack.py"
TOKEN = "0123456789abcdef0123456789abcdef"
PID = 12345
SIZES = (("", 1144), (".resources-start.bin", 392), (".resources.bin", 32768))


def load_helper():
    spec = importlib.util.spec_from_file_location("beamrt_unattended_ack_contract", SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class AcknowledgementContracts(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-ack-contract-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.decoder = self.directory / "receipt_decoder.exe"
        self.decoder.write_bytes(b"fixture bytes must never execute")
        self.decoder_hash = hashlib.sha256(self.decoder.read_bytes()).hexdigest()
        self.record = self.directory / "observation.bindings.bin"
        for ordinal, (suffix, size) in enumerate(SIZES):
            Path(str(self.record) + suffix).write_bytes(bytes([ordinal + 1]) * size)
        self.output = self.directory / "driver-ack.json"
        self.decoded = {"processId": PID, "mode": 1, "profile": 2,
                        "resourceTransportABI": 7, "drawABI": 5,
                        "cbvProbeBytes": 0, "allProofFlagsZero": True}

    def completed(self, value=None, returncode=0):
        data = self.decoded if value is None else value
        return subprocess.CompletedProcess([], returncode, json.dumps(data).encode(), b"")

    def publish(self, run=None, **overrides):
        arguments = {"decoder": self.decoder, "record": self.record, "expected_pid": PID,
                     "token": TOKEN, "output": self.output}
        arguments.update(overrides)
        with ExitStack() as stack:
            stack.enter_context(patch.object(self.helper, "DECODER_SHA256", self.decoder_hash))
            mocked = stack.enter_context(patch.object(self.helper.subprocess, "run",
                side_effect=run if callable(run) else None,
                return_value=self.completed() if run is None or callable(run) else run))
            result = self.helper.publish_ack(**arguments)
        return result, mocked

    def absent(self):
        self.assertFalse(self.output.exists())
        self.assertEqual(list(self.directory.glob(".beamrt-ack-*.tmp")), [])

    def refused(self, run=None, **overrides):
        with self.assertRaises((ValueError, OSError, subprocess.SubprocessError)):
            self.publish(run, **overrides)
        self.absent()

    def test_import_is_inert_without_file_reads_subprocess_or_cli(self):
        with patch.object(subprocess, "run", side_effect=AssertionError("import launched subprocess")), \
                patch.object(Path, "open", side_effect=AssertionError("import read receipt")), \
                patch.object(os, "link", side_effect=AssertionError("import published ack")):
            module = load_helper()
        self.assertTrue(callable(module.publish_ack))

    def test_valid_owned_identity_uses_only_frozen_decoder_and_exact_arguments(self):
        before = tuple(Path(str(self.record) + suffix).read_bytes() for suffix, _ in SIZES)
        ack, mocked = self.publish()
        self.assertEqual(mocked.call_count, 1)
        positional, keywords = mocked.call_args
        self.assertEqual(positional, ((str(self.decoder.resolve()), str(self.record.resolve()), str(PID), "1", "2"),))
        self.assertEqual(keywords, {"stdout": subprocess.PIPE, "stderr": subprocess.PIPE,
                                   "timeout": 20, "check": False})
        self.assertEqual(set(ack), {"token", "kind", "expectedPid", "resourceABI", "profile", "mode", "cbvProbeBytes", "digest"})
        self.assertEqual(ack["token"], TOKEN)
        self.assertEqual(ack["expectedPid"], PID)
        self.assertEqual(ack["kind"], "receipt_validated")
        self.assertEqual(json.loads(self.output.read_bytes()), ack)
        digest = hashlib.sha256(b"BeamRT CPU receipt bundle ABI7\0")
        for (suffix, _), data in zip(SIZES, before):
            digest.update(suffix.encode("ascii") + b"\0")
            digest.update(len(data).to_bytes(8, "little")); digest.update(data)
        self.assertEqual(ack["digest"], digest.hexdigest())
        self.assertEqual(tuple(Path(str(self.record) + suffix).read_bytes() for suffix, _ in SIZES), before)
        self.assertEqual(list(self.directory.glob(".beamrt-ack-*.tmp")), [])

    def test_expected_pid_is_explicit_uint32_not_bool_float_or_inferred(self):
        for pid in (None, False, True, 0, -1, 4294967296, 1.5, "12345"):
            with self.subTest(pid=pid): self.refused(expected_pid=pid)

    def test_token_is_exact_lowercase_hex_and_never_inferred(self):
        for token in (None, 7, "", "a" * 31, "a" * 33, "A" * 32, "g" * 32, TOKEN + "\n"):
            with self.subTest(token=token): self.refused(token=token)

    def test_decoder_name_and_hash_must_both_match_pin(self):
        renamed = self.directory / "other.exe"; shutil.copyfile(self.decoder, renamed)
        self.refused(decoder=renamed)
        self.decoder.write_bytes(b"different executable")
        self.refused()
        missing = self.directory / "missing" / "receipt_decoder.exe"
        self.refused(decoder=missing)

    def test_each_bundle_size_and_presence_is_exact(self):
        for suffix, size in SIZES:
            path = Path(str(self.record) + suffix); original = path.read_bytes()
            for candidate in (b"", original[:-1], original + b"x"):
                with self.subTest(suffix=suffix, size=len(candidate)):
                    path.write_bytes(candidate); self.refused()
            path.unlink(); self.refused(); path.write_bytes(original)
        self.absent()

    def test_output_is_fixed_new_ack_name_in_exact_receipt_parent(self):
        for name in ("validated-ack.json", "other.json", "driver-ack.json.extra"):
            with self.subTest(name=name): self.refused(output=self.directory / name)
        other = self.directory / "other"; other.mkdir()
        self.refused(output=other / "driver-ack.json")
        self.output.write_bytes(b"existing receipt must survive")
        with self.assertRaises(FileExistsError): self.publish()
        self.assertEqual(self.output.read_bytes(), b"existing receipt must survive")

    def test_decoder_failure_exception_timeout_or_output_over_budget_never_publishes(self):
        self.refused(self.completed(returncode=1))
        self.refused(lambda *_args, **_kwargs: (_ for _ in ()).throw(subprocess.TimeoutExpired("fixture", 20)))
        self.refused(subprocess.CompletedProcess([], 0, b" " * 262145, b""))

    def test_malformed_json_duplicate_keys_and_nonfinite_data_refuse(self):
        good = json.dumps(self.decoded)
        bad_outputs = (b"", b"not json", b"\xff", b"[]", b"null", b"true",
                       (good[:-1] + ',"processId":12345}').encode(),
                       (good[:-1] + ',"extra":NaN}').encode(),
                       (good[:-1] + ',"extra":Infinity}').encode(),
                       (good[:-1] + ',"nested":{"number":1e9999}}').encode())
        for stdout in bad_outputs:
            with self.subTest(stdout=stdout[:50]):
                self.refused(subprocess.CompletedProcess([], 0, stdout, b""))

    def test_foreign_pid_mode_profile_abi_probe_and_nonzero_proof_refuse(self):
        mutants = {"processId": PID + 1, "mode": 0, "profile": 1,
                   "resourceTransportABI": 6, "drawABI": 4,
                   "cbvProbeBytes": 4, "allProofFlagsZero": False}
        for key, value in mutants.items():
            with self.subTest(field=key):
                decoded = dict(self.decoded); decoded[key] = value
                self.refused(self.completed(decoded))
                decoded = dict(self.decoded); del decoded[key]
                self.refused(self.completed(decoded))
        for key in ("processId", "mode", "profile", "resourceTransportABI", "drawABI", "cbvProbeBytes"):
            decoded = dict(self.decoded); decoded[key] = True
            self.refused(self.completed(decoded))
        decoded = dict(self.decoded); decoded["allProofFlagsZero"] = 1
        self.refused(self.completed(decoded))

    def test_any_bundle_mutation_during_decode_invalidates_ack(self):
        for suffix, _ in SIZES:
            path = Path(str(self.record) + suffix); original = path.read_bytes()
            def mutate(*_args, **_kwargs):
                path.write_bytes(bytes([original[0] ^ 1]) + original[1:])
                return self.completed()
            self.refused(mutate)
            path.write_bytes(original)

    def test_decoder_binary_change_during_decode_invalidates_ack(self):
        def mutate(*_args, **_kwargs):
            self.decoder.write_bytes(b"changed while running")
            return self.completed()
        self.refused(mutate)

    def test_atomic_publication_refuses_output_race_and_cleans_temporary(self):
        def race(*_args, **_kwargs):
            self.output.write_bytes(b"racing owner wins")
            return self.completed()
        with self.assertRaises(FileExistsError): self.publish(race)
        self.assertEqual(self.output.read_bytes(), b"racing owner wins")
        self.assertEqual(list(self.directory.glob(".beamrt-ack-*.tmp")), [])

    def test_publication_error_leaves_no_ack_or_partial_temporary(self):
        with patch.object(self.helper.os, "link", side_effect=PermissionError("injected link refusal")):
            self.refused()


class FrozenDecoderIntegration(unittest.TestCase):
    @unittest.skipUnless(os.name == "nt", "Windows read-only native decoder fixture")
    def test_reviewed_decoder_accepts_only_copied_historical_offline_bundle(self):
        decoder = ROOT / ".beamrt-validation/prepared-interned-observation-33567a29140a4465a2d4e18ed6a85d5b/analyzer/receipt_decoder.exe"
        source = ROOT / ".beamrt-validation/native-startup-resource-e96d984928844cce8d4f8e2882c5be70/process-tests-52852-243485468/resource-interned-hardware.bindings.bin"
        if not decoder.is_file() or not all(Path(str(source) + suffix).is_file() for suffix, _ in SIZES):
            self.skipTest("historical frozen offline fixture is not present in this checkout")
        helper = load_helper()
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest()
                  for path in [decoder] + [Path(str(source) + suffix) for suffix, _ in SIZES]}
        with tempfile.TemporaryDirectory(prefix="beamrt-frozen-decoder-contract-") as temporary:
            directory = Path(temporary); record = directory / "copied.bindings.bin"
            for suffix, _ in SIZES: shutil.copyfile(Path(str(source) + suffix), Path(str(record) + suffix))
            # Historical fixture identity only: this is not a discovered or owned live PID.
            fixture_pid = struct.unpack_from("<I", record.read_bytes(), 8)[0]
            ack = helper.publish_ack(decoder, record, fixture_pid, TOKEN, directory / "driver-ack.json")
            self.assertEqual(ack["expectedPid"], fixture_pid)
            self.assertEqual(ack["resourceABI"], 7)
            self.assertEqual(ack["profile"], 2)
            self.assertEqual(ack["cbvProbeBytes"], 0)
        self.assertEqual({path: hashlib.sha256(path.read_bytes()).hexdigest() for path in before}, before)


if __name__ == "__main__":
    unittest.main()
