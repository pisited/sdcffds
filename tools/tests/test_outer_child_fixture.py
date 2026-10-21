"""Inert/mocked guards for the fixed outer-owner fixture coordinator.

No test in this module creates a native process or loads a DLL. Mocked lease
ordering is control-flow coverage, not physical Windows lock or exit evidence.
"""
from contextlib import contextmanager, redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "native/startup/unattended/outer_child_fixture.py"


def load_coordinator(name):
    spec = importlib.util.spec_from_file_location(name, SOURCE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COORDINATOR = load_coordinator("beamrt_outer_fixture_unit_guards")


@contextmanager
def reviewed_environment():
    """Model fixed Windows review names without executing any helper/artifact."""
    with tempfile.TemporaryDirectory(prefix="beamrt-outer-review-") as temporary:
        workspace = Path(temporary) / "workspace"
        source = workspace / "native/startup/unattended/outer_child_fixture.py"
        source.parent.mkdir(parents=True)
        for leaf in ("outer_child_fixture.py", "outer_child_owner.py", "protected_inputs.py"):
            (source.parent / leaf).write_bytes(b"# inert mocked fixture helper data\n")
        validation = workspace / ".beamrt-validation"
        artifacts = validation / ("outer-child-" + "a" * 32) / "native-b2"
        artifacts.mkdir(parents=True)
        files = {role: artifacts / leaf for role, leaf in COORDINATOR.FIXED_ARTIFACTS.items()}
        for role, path in files.items():
            path.write_bytes(("inert non-executable fixture data: " + role).encode("ascii"))
        output = validation / ("oc-" + "b" * 12)

        def digest(path):
            for role, fixed in files.items():
                if path == fixed:
                    return COORDINATOR.FIXED_SHA256[role]
            return hashlib.sha256(path.read_bytes()).hexdigest()

        with mock.patch.object(COORDINATOR, "__file__", str(source)), \
                mock.patch.object(COORDINATOR, "os", types.SimpleNamespace(name="nt", fsync=os.fsync)), \
                mock.patch.object(COORDINATOR, "_digest", side_effect=digest) as hasher:
            yield types.SimpleNamespace(source=source, workspace=workspace, validation=validation,
                artifacts=artifacts, output=output, files=files, digest=digest, hasher=hasher)


class Protection:
    def __init__(self, events):
        self.events = events
        self.opened = False
        self.claimed = False

    def open(self):
        self.events.append("protection-open")
        self.opened = True

    def claim_attempt(self, token, digest):
        if not self.opened:
            raise AssertionError("claim without open lease")
        self.events.append(("claim", token, digest))
        self.claimed = True

    def read_bytes(self, path):
        if not self.opened or not self.claimed:
            raise AssertionError("helper read outside claimed lease")
        self.events.append("protected-read")
        return Path(path).read_bytes()

    def close(self):
        self.events.append("protection-close")
        self.opened = False


class RetentionTestBudgetExceeded(BaseException):
    """Escape a regressed mock loop without its ordinary-error recovery catch."""


class Clock:
    def __init__(self):
        self.value = 0

    def now(self):
        return self.value

    def sleep(self, _seconds):
        self.value += 1
        if self.value > 100:
            raise RetentionTestBudgetExceeded("mock retention loop exceeded its deterministic test budget")


class OuterChildFixtureTests(unittest.TestCase):
    def test_import_is_inert_even_when_native_launch_and_output_are_forbidden(self):
        with mock.patch.object(subprocess, "Popen", side_effect=AssertionError("process creation")), \
                mock.patch.object(Path, "mkdir", side_effect=AssertionError("output creation")):
            module = load_coordinator("beamrt_outer_fixture_inert_import")
        self.assertEqual(module.PROFILE, "outer-owned-fixed-disposable-v1")
        self.assertTrue(callable(module.review))
        self.assertTrue(callable(module.execute))

    def test_review_rejects_non_windows_without_reading_or_creating_outputs(self):
        with mock.patch.object(COORDINATOR, "os", types.SimpleNamespace(name="posix")), \
                mock.patch.object(COORDINATOR, "_digest", side_effect=AssertionError("input opened")), \
                mock.patch.object(Path, "mkdir", side_effect=AssertionError("output created")):
            with self.assertRaisesRegex(OSError, "require Windows"):
                COORDINATOR.review("irrelevant", "irrelevant")

    def test_review_is_inert_and_joins_all_fixed_inputs(self):
        with reviewed_environment() as env, \
                mock.patch.object(COORDINATOR, "_load", side_effect=AssertionError("helper executed")), \
                mock.patch.object(COORDINATOR, "_run_case", side_effect=AssertionError("case executed")), \
                mock.patch.object(COORDINATOR, "_new_json", side_effect=AssertionError("output written")):
            plan, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            self.assertFalse(env.output.exists())
            self.assertEqual(files, env.files)
            self.assertEqual(set(helpers), {"outer_child_owner.py", "protected_inputs.py", "outer_child_fixture.py"})
            self.assertEqual(len(plan["manifest"]), 7)
            self.assertFalse(plan["gameSelected"])
            self.assertFalse(plan["hostTerminationAvailable"])
            self.assertFalse(plan["processLookupAvailable"])
            self.assertEqual(plan["overallSeconds"], 2)
            self.assertEqual(plan["normalGraceSeconds"], 1)
            self.assertEqual(plan["terminationWaitMilliseconds"], 5000)
            self.assertEqual(env.hasher.call_count, 7)
            unsigned = dict(plan)
            observed = unsigned.pop("reviewSHA256")
            self.assertEqual(observed, hashlib.sha256(COORDINATOR._canonical(unsigned)).hexdigest())

    def test_every_binary_has_a_separate_fixed_name_and_pin(self):
        self.assertEqual(COORDINATOR.FIXED_ARTIFACTS, {
            "host": "beamrt_startup_host.exe", "faultHost": "beamrt_startup_fault_host.exe",
            "child": "beamrt_startup_fixture.exe", "dll": "beamrt_startup_bootstrap.dll",
        })
        self.assertEqual(set(COORDINATOR.FIXED_SHA256), set(COORDINATOR.FIXED_ARTIFACTS))
        self.assertEqual(len(set(COORDINATOR.FIXED_SHA256.values())), 4)
        for digest in COORDINATOR.FIXED_SHA256.values():
            self.assertRegex(digest, r"^[0-9a-f]{64}$")

    def test_pin_drift_refuses_before_output_creation(self):
        for changed in COORDINATOR.FIXED_ARTIFACTS:
            with self.subTest(role=changed), reviewed_environment() as env:
                def changed_digest(path):
                    return "0" * 64 if path == env.files[changed] else env.digest(path)

                with mock.patch.object(COORDINATOR, "_digest", side_effect=changed_digest):
                    with self.assertRaisesRegex(ValueError, "artifact pin differs"):
                        COORDINATOR.review(env.artifacts, env.output)
                self.assertFalse(env.output.exists())

    def test_nonfixture_artifact_locations_and_game_paths_refuse(self):
        with reviewed_environment() as env:
            for artifacts in (env.artifacts.parent / "native-b1", env.validation / "native-b2",
                              env.validation / "outer-child-INVALID" / "native-b2",
                              env.validation / "BeamNG.drive.x64.exe"):
                with self.subTest(path=artifacts), self.assertRaisesRegex(ValueError, "fixed new outer-child"):
                    COORDINATOR.review(artifacts, env.output)
            self.assertEqual(env.hasher.call_count, 0)
            self.assertFalse(env.output.exists())

    def test_output_must_be_fresh_short_and_directly_inside_validation(self):
        with reviewed_environment() as env:
            for output in (env.validation / "not-a-fixture", env.validation / ("oc-" + "b" * 11),
                           env.validation / ("oc-" + "b" * 33), env.output / "nested", env.workspace / env.output.name):
                with self.subTest(path=output), self.assertRaisesRegex(ValueError, "fresh short oc-hex"):
                    COORDINATOR.review(env.artifacts, output)
            env.output.mkdir()
            sentinel = env.output / "retained.txt"
            sentinel.write_bytes(b"unchanged")
            with self.assertRaisesRegex(FileExistsError, "one shot"):
                COORDINATOR.review(env.artifacts, env.output)
            self.assertEqual(sentinel.read_bytes(), b"unchanged")
            self.assertEqual(env.hasher.call_count, 0)

    def test_all_seven_case_definitions_have_the_expected_ownership_outcome(self):
        self.assertEqual(COORDINATOR.CASE_DEFINITIONS, (
            ("normal", "cooperative", None, True, False),
            ("crash-pre", "cooperative", "crash-before-insert", False, False),
            ("crash-co", "cooperative", "crash-after-resume", True, False),
            ("crash-ig", "ignore", "crash-after-resume", True, True),
            ("hang-pre", "cooperative", "hang-before-insert", False, False),
            ("hang-co", "cooperative", "hang-after-resume", True, False),
            ("hang-ig", "ignore", "hang-after-resume", True, True),
        ))

    def test_host_arguments_have_fixed_target_hashes_policy_and_no_game_override(self):
        with reviewed_environment() as env:
            plan, files, _helpers = COORDINATOR.review(env.artifacts, env.output)
            child_args = ("--owned-fixture-mode", "cooperative")
            arguments = COORDINATOR._host_arguments(files, env.output / "normal", child_args, plan["manifest"])
            prefix, tail = arguments[:arguments.index("--")], arguments[arguments.index("--") + 1:]
            self.assertEqual(tail, child_args)
            for flag, expected in (("--target", str(files["child"])), ("--dll", str(files["dll"])),
                                   ("--expected-target-sha256", COORDINATOR.FIXED_SHA256["child"]),
                                   ("--expected-dll-sha256", COORDINATOR.FIXED_SHA256["dll"]),
                                   ("--owned-overall-seconds", "2"), ("--owned-normal-grace-seconds", "1"),
                                   ("--owned-run-token", COORDINATOR.TOKEN),
                                   ("--acknowledge-owned-force-close", "exact-created-child-after-normal-quit")):
                self.assertEqual(prefix[prefix.index(flag) + 1], expected)
            self.assertIn("--launch-reviewed", prefix)
            self.assertNotIn("--outer-owned-channel", prefix)
            self.assertNotIn("--outer-config-sha256", prefix)
            self.assertNotIn("BeamNG", " ".join(arguments))

    def test_execute_requires_the_exact_review_digest_before_loading_or_output(self):
        with reviewed_environment() as env:
            plan, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            with mock.patch.object(COORDINATOR, "_load", side_effect=AssertionError("helper executed")):
                for supplied in (None, "", "0" * 64, plan["reviewSHA256"].upper()):
                    with self.subTest(digest=supplied), self.assertRaisesRegex(ValueError, "unchanged review digest"):
                        COORDINATOR.execute(plan, files, helpers, supplied)
            self.assertFalse(env.output.exists())

    def test_main_defaults_to_review_and_requires_runtime_digest(self):
        with reviewed_environment() as env:
            base = ("outer_child_fixture.py", "--artifacts", str(env.artifacts), "--output", str(env.output))
            with mock.patch.object(sys, "argv", list(base)), \
                    mock.patch.object(COORDINATOR, "execute", side_effect=AssertionError("runtime entered")), \
                    redirect_stdout(io.StringIO()):
                self.assertEqual(COORDINATOR.main(), 0)
            self.assertFalse(env.output.exists())
            for extra in (("--run-tests",), ("--run-tests", "--expected-review-sha256", "0" * 64),
                          ("--expected-review-sha256", "0" * 64)):
                with self.subTest(arguments=extra), mock.patch.object(sys, "argv", list(base + extra)), \
                        redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    self.assertEqual(COORDINATOR.main(), 1)
                self.assertFalse(env.output.exists())

    def test_fresh_review_after_helper_change_refuses_the_previous_digest(self):
        with reviewed_environment() as env:
            original, _files, _helpers = COORDINATOR.review(env.artifacts, env.output)
            (env.source.parent / "outer_child_owner.py").write_bytes(b"# changed inert source fixture\n")
            changed, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            self.assertNotEqual(original["reviewSHA256"], changed["reviewSHA256"])
            with self.assertRaisesRegex(ValueError, "unchanged review digest"):
                COORDINATOR.execute(changed, files, helpers, original["reviewSHA256"])
            self.assertFalse(env.output.exists())

    def test_loader_hash_check_precedes_code_execution_and_failed_import_is_removed(self):
        with tempfile.TemporaryDirectory(prefix="beamrt-outer-load-") as temporary:
            path = Path(temporary) / "helper.py"
            with self.assertRaisesRegex(ValueError, "helper source changed"):
                COORDINATOR._load(path, b"raise AssertionError('must not run')", "0" * 64)
            image = b"VALUE = 7\n"
            digest = hashlib.sha256(image).hexdigest()
            module = COORDINATOR._load(path, image, digest)
            self.assertEqual(module.VALUE, 7)
            sys.modules.pop(module.__name__, None)
            bad = b"raise RuntimeError('inert helper fixture failure')\n"
            bad_digest = hashlib.sha256(bad).hexdigest()
            name = "beamrt_outer_fixture_helper_" + bad_digest[:16]
            with self.assertRaisesRegex(RuntimeError, "inert helper fixture failure"):
                COORDINATOR._load(path, bad, bad_digest)
            self.assertNotIn(name, sys.modules)

    def test_execute_keeps_claimed_protection_around_every_case_cleanup(self):
        with reviewed_environment() as env:
            plan, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            events = []
            protection = Protection(events)
            protection_module = types.SimpleNamespace(ProtectedInputs=lambda manifest, output: protection)
            owner_module = types.SimpleNamespace()

            def loader(path, image, expected):
                events.append(("load", path.name))
                return protection_module if path.name == "protected_inputs.py" else owner_module

            def run_case(_owner, _files, directory, definition, manifest, digest):
                self.assertTrue(protection.opened and protection.claimed)
                self.assertEqual(digest, plan["reviewSHA256"])
                events.extend((("case", definition[0]), "child-exit", "host-self-stop", "owner-close"))
                return {"case": definition[0], "status": "pass"}

            with mock.patch.object(COORDINATOR, "_load", side_effect=loader), \
                    mock.patch.object(COORDINATOR, "_run_case", side_effect=run_case), redirect_stdout(io.StringIO()):
                result = COORDINATOR.execute(plan, files, helpers, plan["reviewSHA256"])
            self.assertTrue(result["allPassed"])
            self.assertEqual(result["cases"], 7)
            self.assertEqual(events[-1], "protection-close")
            self.assertEqual(events.count("owner-close"), 7)
            self.assertFalse(protection.opened)
            with self.assertRaises(FileExistsError):
                COORDINATOR.review(env.artifacts, env.output)

    def test_claim_failure_cannot_reach_owner_creation_or_case_execution(self):
        with reviewed_environment() as env:
            plan, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            events = []
            protection = Protection(events)
            protection.claim_attempt = mock.Mock(side_effect=FileExistsError("consumed attempt"))
            protection_module = types.SimpleNamespace(ProtectedInputs=lambda manifest, output: protection)
            with mock.patch.object(COORDINATOR, "_load", return_value=protection_module) as loader, \
                    mock.patch.object(COORDINATOR, "_run_case", side_effect=AssertionError("case executed")):
                with self.assertRaisesRegex(FileExistsError, "consumed attempt"):
                    COORDINATOR.execute(plan, files, helpers, plan["reviewSHA256"])
            self.assertEqual(loader.call_count, 1)
            self.assertEqual(events, ["protection-open", "protection-close"])
            self.assertTrue(env.output.is_dir())

    def test_retention_threshold_does_not_release_before_child_host_and_publisher(self):
        clock, closes = Clock(), []
        with tempfile.TemporaryDirectory(prefix="beamrt-outer-retain-") as temporary:
            directory = Path(temporary)

            class Owner:
                def report(self):
                    return {"processExitVerified": clock.value >= 3, "normalRequested": True,
                            "normalCompleted": clock.value >= 8}

                def host_poll(self):
                    return 0 if clock.value >= 12 else None

                def close(self):
                    if clock.value < 12:
                        raise AssertionError("capabilities closed before all exit/publisher evidence")
                    closes.append(clock.value)
                    return self.report()

            result = {}
            with redirect_stdout(io.StringIO()):
                COORDINATOR._retain_until_finished(Owner(), True, directory, result,
                    diagnostic_after=2, clock=clock.now, sleep=clock.sleep)
            self.assertEqual(closes, [12])
            self.assertTrue(result["retentionRequired"])
            self.assertTrue(result["hostExitVerified"])
            self.assertTrue(result["hostAliveAtIndependentChildExit"])
            self.assertTrue(result["finalChild"]["normalCompleted"])
            self.assertTrue((directory / "retention-diagnostic.json").is_file())

    def test_retention_observation_and_diagnostic_errors_never_release_early(self):
        clock, closes = Clock(), []

        class Owner:
            def report(self):
                if clock.value < 2:
                    raise OSError("child observation temporarily unknown")
                return {"processExitVerified": True, "normalRequested": False, "normalCompleted": False}

            def host_poll(self):
                if clock.value < 4:
                    raise OSError("host observation temporarily unknown")
                return 77

            def close(self):
                if clock.value < 4:
                    raise AssertionError("unknown liveness released")
                closes.append(clock.value)
                return self.report()

        result = {}
        with mock.patch.object(COORDINATOR, "_new_json", side_effect=OSError("diagnostic destination unavailable")), \
                redirect_stdout(io.StringIO()):
            COORDINATOR._retain_until_finished(Owner(), True, Path("not-opened"), result,
                diagnostic_after=1, clock=clock.now, sleep=clock.sleep)
        self.assertEqual(closes, [4])
        self.assertIn("temporarily unknown", result["retentionChildObservationError"])
        self.assertIn("temporarily unknown", result["retentionHostObservationError"])
        self.assertIn("destination unavailable", result["retentionDiagnosticError"])
        self.assertTrue(result["hostExitVerified"])

    def test_retention_retries_refused_owner_close_without_discarding_capability(self):
        clock, attempts = Clock(), []

        class Owner:
            def report(self):
                return {"processExitVerified": True, "normalRequested": False, "normalCompleted": False}

            def host_poll(self):
                return 0

            def close(self):
                attempts.append(clock.value)
                if len(attempts) < 3:
                    raise RuntimeError("retained owner not yet closeable")
                return self.report()

        result = {}
        COORDINATOR._retain_until_finished(Owner(), True, Path("not-opened"), result,
            clock=clock.now, sleep=clock.sleep)
        self.assertEqual(attempts, [0, 1, 2])
        self.assertIn("not yet closeable", result["retentionCloseError"])
        self.assertTrue(result["finalChild"]["processExitVerified"])

    def test_broken_progress_sink_does_not_release_unknown_liveness(self):
        clock, closes = Clock(), []

        class Owner:
            def report(self):
                return {"processExitVerified": clock.value >= 3, "normalRequested": False, "normalCompleted": False}

            def host_poll(self):
                return 0 if clock.value >= 4 else None

            def close(self):
                if clock.value < 4:
                    raise AssertionError("progress failure released an active capability")
                closes.append(clock.value)
                return self.report()

        result = {}
        with mock.patch.object(COORDINATOR, "_new_json"), \
                mock.patch("builtins.print", side_effect=BrokenPipeError("fixture stdout closed")):
            COORDINATOR._retain_until_finished(Owner(), True, Path("not-opened"), result,
                diagnostic_after=1, clock=clock.now, sleep=clock.sleep)
        self.assertEqual(closes, [4])
        self.assertIn("stdout closed", result["retentionProgressError"])
        self.assertTrue(result["finalChild"]["processExitVerified"])
        self.assertTrue(result["hostExitVerified"])

    def test_initial_diagnostic_clock_error_uses_fallback_without_releasing(self):
        clock, closes = Clock(), []

        class Owner:
            def report(self):
                return {"processExitVerified": clock.value >= 3, "normalRequested": False, "normalCompleted": False}

            def close(self):
                closes.append(clock.value)
                return self.report()

        result = {}
        with mock.patch.object(COORDINATOR, "time", types.SimpleNamespace(monotonic=clock.now, sleep=clock.sleep)):
            COORDINATOR._retain_until_finished(Owner(), False, Path("not-opened"), result,
                clock=mock.Mock(side_effect=OSError("fixture clock unavailable")), sleep=clock.sleep)
        self.assertEqual(closes, [3])
        self.assertIn("clock unavailable", result["retentionClockError"])
        self.assertTrue(result["finalChild"]["processExitVerified"])

    def test_retention_without_created_host_never_polls_or_claims_host_exit(self):
        clock, closes = Clock(), []

        class Owner:
            def report(self):
                return {"processExitVerified": clock.value >= 2, "normalRequested": False, "normalCompleted": False}

            def host_poll(self):
                raise AssertionError("no host was created")

            def close(self):
                closes.append(clock.value)
                return self.report()

        result = {}
        COORDINATOR._retain_until_finished(Owner(), False, Path("not-opened"), result,
            clock=clock.now, sleep=clock.sleep)
        self.assertEqual(closes, [2])
        self.assertFalse(result["hostExitVerified"])
        self.assertIsNone(result["hostExitCode"])

    def test_exception_after_host_launch_retains_inputs_until_host_self_exit(self):
        self._exceptional_case_retention(post_create_factory_error=False)

    def test_controlled_post_create_failure_retains_actual_owner_until_child_exit(self):
        self._exceptional_case_retention(post_create_factory_error=True)

    def _exceptional_case_retention(self, *, post_create_factory_error):
        with reviewed_environment() as env:
            plan, files, helpers = COORDINATOR.review(env.artifacts, env.output)
            events, clock = [], Clock()
            protection = Protection(events)
            test = self

            class CreationError(RuntimeError):
                def __init__(self, owner):
                    super().__init__("controlled post-create fixture failure")
                    self.owner = owner

            class Owner:
                def launch_host(self, *_args):
                    test.assertTrue(protection.opened)
                    events.append("host-created")

                def await_setup_and_resume(self, **_kwargs):
                    raise KeyError("unexpected setup fixture exception")

                def finish(self):
                    test.assertTrue(protection.opened)
                    events.append("child-finish")
                    return self.report()

                def report(self):
                    test.assertTrue(protection.opened)
                    return {"processExitVerified": clock.value >= 2,
                            "normalRequested": False, "normalCompleted": False}

                def host_poll(self):
                    if post_create_factory_error:
                        raise AssertionError("host absent after factory refusal")
                    test.assertTrue(protection.opened)
                    events.append(("host-poll", clock.value))
                    return 0 if clock.value >= 4 else None

                def close(self):
                    test.assertTrue(protection.opened)
                    test.assertGreaterEqual(clock.value, 2 if post_create_factory_error else 4)
                    events.append("owner-close")
                    return self.report()

            owner = Owner()

            def create(*_args, **_kwargs):
                test.assertTrue(protection.opened and protection.claimed)
                events.append("child-created")
                if post_create_factory_error:
                    raise CreationError(owner)
                return owner

            owner_module = types.SimpleNamespace(OuterChildOwner=types.SimpleNamespace(create=create),
                OwnerCreationError=CreationError, FORCED_EXIT_CODE=0x42525446)
            protection_module = types.SimpleNamespace(ProtectedInputs=lambda manifest, output: protection)
            retain = COORDINATOR._retain_until_finished

            def loader(path, _image, _expected):
                return protection_module if path.name == "protected_inputs.py" else owner_module

            def bounded_retention(*args, **kwargs):
                return retain(*args, **kwargs, clock=clock.now, sleep=clock.sleep)

            with mock.patch.object(COORDINATOR, "_load", side_effect=loader), \
                    mock.patch.object(COORDINATOR, "_retain_until_finished", side_effect=bounded_retention), \
                    redirect_stdout(io.StringIO()):
                result = COORDINATOR.execute(plan, files, helpers, plan["reviewSHA256"])
            self.assertFalse(result["allPassed"])
            self.assertEqual(result["cases"], 1)
            self.assertIn("failure", result["results"][0])
            self.assertTrue(result["results"][0]["finalChild"]["processExitVerified"])
            self.assertLess(events.index("child-finish"), events.index("owner-close"))
            self.assertLess(events.index("owner-close"), events.index("protection-close"))
            self.assertEqual(events[-1], "protection-close")
            if post_create_factory_error:
                self.assertNotIn("host-created", events)
                self.assertFalse(result["results"][0]["hostExitVerified"])
            else:
                self.assertTrue(result["results"][0]["hostAliveAtIndependentChildExit"])
                self.assertIn(("host-poll", 0), events)
                self.assertIn(("host-poll", 4), events)

    def test_hang_cases_require_original_deadline_and_after_resume_full_grace(self):
        source = SOURCE.read_text(encoding="utf-8")
        self.assertIn('child["elapsedMilliseconds"] >= 2000', source)
        self.assertIn('child["normalRequestMilliseconds"] >= 2000', source)
        self.assertIn('child["forceAttemptMilliseconds"] >= child["normalRequestMilliseconds"] + 1000', source)

    def test_source_does_not_offer_host_kill_process_lookup_or_game_cli(self):
        source = SOURCE.read_text(encoding="utf-8")
        for forbidden in (".kill(", ".terminate(", "TerminateProcess(", "OpenProcess(", "taskkill",
                          "TerminateJobObject(", "--pid", "--game", "--backend", "--target"):
            if forbidden == "--target":
                # Only a fixed host argument is present, never a CLI override.
                self.assertNotIn('parser.add_argument("--target"', source)
            else:
                self.assertNotIn(forbidden, source)
        for name in ("--artifacts", "--output", "--run-tests", "--expected-review-sha256"):
            self.assertIn('parser.add_argument("' + name + '"', source)
        self.assertIn("forceAttemptMilliseconds", source)
        self.assertIn("normalRequestMilliseconds", source)
        self.assertIn("hostAliveAtIndependentChildExit", source)


if __name__ == "__main__":
    unittest.main()
