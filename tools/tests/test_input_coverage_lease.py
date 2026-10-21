"""Bounded bulk physical leases, using the original protected-input scope."""
from contextlib import ExitStack
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = ROOT / "native/startup/unattended"
DIGEST = hashlib.sha256(b"one").hexdigest()


def load_source(name):
    spec = importlib.util.spec_from_file_location("beamrt_coverage_contract_" + name,
                                                  DIRECTORY / (name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FileBackend:
    def __init__(self, count=513):
        self.files = {fr"C:\frozen\input-{index:05d}.py": b"one"
                      for index in range(count)}
        self.identities = {path: (1, 0, index + 1) for index, path in enumerate(self.files)}
        self.handles, self.closed, self.events, self.positions = {}, [], [], {}
        self.next_handle, self.existing = 0, set()

    def allocate(self, kind, path):
        self.next_handle += 1
        self.handles[self.next_handle] = kind, path
        self.positions[self.next_handle] = 0
        self.events.append((kind, path))
        return self.next_handle

    def check_fixed_root(self, root):
        self.events.append(("fixed", root))

    def open_directory(self, path):
        return self.allocate("directory", path)

    def open_input(self, path):
        return self.allocate("input", path), self.identities[path]

    def size(self, handle):
        return len(self.files[self.handles[handle][1]])

    def chunks(self, handle, maximum):
        self.positions[handle] = 0
        image = self.files[self.handles[handle][1]]
        if len(image) > maximum:
            raise ValueError("fixture read budget exceeded")
        self.positions[handle] = len(image)
        yield image

    def position(self, handle):
        return self.positions[handle]

    def seek(self, handle, position):
        self.positions[handle] = position

    def exists(self, path):
        return path in self.existing

    def close(self, handle):
        if handle in self.closed:
            raise AssertionError("duplicate close")
        self.closed.append(handle)


class CoverageLeaseContracts(unittest.TestCase):
    def setUp(self):
        self.module = load_source("input_coverage_lease")
        self.old = load_source("protected_inputs")
        self.backend = FileBackend()
        self.manifest = {path: hashlib.sha256(data).hexdigest()
                         for path, data in self.backend.files.items()}
        self.factory_calls, self.backend_calls, self.inventory_calls = [], [], []

    def factory(self, manifest, run_directory, **options):
        self.factory_calls.append((dict(manifest), run_directory, dict(options)))
        return self.old.ProtectedInputs(manifest, run_directory, **options)

    def make_backend(self):
        self.backend_calls.append(True)
        return self.backend

    def inventory(self):
        self.inventory_calls.append(len([kind for kind, _ in self.backend.events if kind == "input"]))
        return True

    def lease(self, **options):
        options.setdefault("protector_factory", self.factory)
        options.setdefault("backend_factory", self.make_backend)
        options.setdefault("inventory_check", self.inventory)
        return self.module.CoverageLease(self.manifest, r"C:\evidence\run", **options)

    def assert_released(self):
        self.assertEqual(set(self.backend.closed), set(self.backend.handles))
        self.assertEqual(len(self.backend.closed), len(self.backend.handles))

    def test_import_is_inert_and_does_not_create_backends_or_processes(self):
        with ExitStack() as stack:
            stack.enter_context(patch.object(subprocess, "Popen", side_effect=AssertionError("process created")))
            stack.enter_context(patch.object(os, "open", side_effect=AssertionError("file created")))
            stack.enter_context(patch.object(os, "system", side_effect=AssertionError("shell invoked")))
            stack.enter_context(patch.object(Path, "open", side_effect=AssertionError("path opened")))
            self.assertTrue(callable(load_source("input_coverage_lease").CoverageLease))
        self.assertEqual(self.backend.events, [])

    def test_dependencies_are_required_and_validated_without_side_effects(self):
        with self.assertRaises(TypeError):
            self.module.CoverageLease(self.manifest, r"C:\evidence\run")
        for key in ("protector_factory", "backend_factory", "inventory_check"):
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.lease(**{key: None})
        self.assertEqual(self.backend.events, [])
        self.assertEqual(self.backend_calls, [])

    def test_original_limits_remain_unchanged_and_bulk_limits_are_fixed(self):
        self.assertEqual(self.old.MAX_FILES, 512)
        self.assertEqual(self.module.BATCH_FILES, 512)
        self.assertEqual(self.module.MAX_INPUTS, 8192)
        self.assertEqual(self.module.MAX_FILE_BYTES, self.old.MAX_FILE_BYTES)
        self.assertEqual(self.module.MAX_TOTAL_BYTES, self.old.MAX_TOTAL_BYTES)
        with self.assertRaises(ValueError):
            self.old.ProtectedInputs(self.manifest, r"C:\evidence\run", _backend=self.backend)

    def test_real_old_factory_513_inputs_are_held_as_512_and_1_on_one_backend(self):
        with self.lease() as lease:
            self.assertEqual([len(call[0]) for call in self.factory_calls], [512, 1])
            self.assertIs(self.factory_calls[0][2]["_backend"], self.factory_calls[1][2]["_backend"])
            self.assertEqual(self.backend_calls, [True])
            self.assertEqual(self.inventory_calls, [0, 513])
            self.assertEqual(lease.digests, self.manifest)
            self.assertEqual(self.backend.closed, [])
            copy = lease.digests
            copy.clear()
            self.assertEqual(lease.digests, self.manifest)
        self.assert_released()

    def test_maximum_count_is_accepted_but_next_input_refuses_before_factories(self):
        manifest = {fr"C:\frozen\{index}.py": DIGEST for index in range(8192)}
        self.module.CoverageLease(manifest, r"C:\evidence\run", protector_factory=self.factory,
                                  backend_factory=self.make_backend, inventory_check=self.inventory)
        manifest[r"C:\frozen\extra.py"] = DIGEST
        with self.assertRaises(ValueError):
            self.module.CoverageLease(manifest, r"C:\evidence\run", protector_factory=self.factory,
                                      backend_factory=self.make_backend, inventory_check=self.inventory)
        self.assertEqual(self.backend_calls, [])

    def test_manifest_and_run_shape_refusals_are_pure(self):
        invalid = ({}, None, [], [(r"C:\one", DIGEST)], {r"C:\one": "A" * 64},
            {r"C:\one": False}, {"C:\\": DIGEST}, {r"C:\one": "0" * 63})
        for manifest in invalid:
            with self.subTest(manifest=manifest), self.assertRaises((TypeError, ValueError)):
                self.module.CoverageLease(manifest, r"C:\evidence\run", protector_factory=self.factory,
                                          backend_factory=self.make_backend, inventory_check=self.inventory)
        for run in ("C:\\", "relative", r"\\server\share\run", r"C:\run\..\other"):
            with self.subTest(run=run), self.assertRaises(ValueError):
                self.module.CoverageLease(self.manifest, run, protector_factory=self.factory,
                                          backend_factory=self.make_backend, inventory_check=self.inventory)
        self.assertEqual(self.backend_calls, [])

    def test_ambiguous_paths_and_case_aliases_are_rejected_before_open(self):
        paths = ("", r"C:relative", r"\rooted", r"\\?\C:\one", r"\\.\C:\one",
                 r"C:\a\.\b", r"C:\a\..\b", "C:\\a\\", "C:\\a\\b.", "C:\\a\\b ",
                 r"C:\a\b:stream", r"C:\a\NUL.txt", r"C:\a\LPT².log", r"C:\a\CONIN$",
                 r"C:\a\b?c", "C:\\a\\bad\x00name")
        for path in paths:
            with self.subTest(path=repr(path)), self.assertRaises(ValueError):
                self.module.CoverageLease({path: DIGEST}, r"C:\evidence\run", protector_factory=self.factory,
                                          backend_factory=self.make_backend, inventory_check=self.inventory)
        for alias in (r"c:\FROZEN\ONE.py", "C:/frozen/one.py"):
            with self.subTest(alias=alias), self.assertRaises(ValueError):
                self.module.CoverageLease({r"C:\frozen\one.py": DIGEST, alias: DIGEST}, r"C:\evidence\run",
                                          protector_factory=self.factory, backend_factory=self.make_backend,
                                          inventory_check=self.inventory)
        self.assertEqual(self.backend_calls, [])

    def test_manifest_is_snapshotted_before_caller_mutates_original_mapping(self):
        lease = self.lease()
        original = dict(self.manifest)
        self.manifest.clear()
        with lease:
            self.assertEqual(lease.digests, original)
            self.assertEqual(len(self.factory_calls), 2)

    def test_preopen_inventory_requires_exact_true_and_never_opens_on_refusal(self):
        for result in (False, None, 1, "yes", [], {}):
            with self.subTest(result=result):
                lease = self.lease(inventory_check=lambda: result)
                with self.assertRaises(ValueError):
                    lease.open()
                with self.assertRaises(RuntimeError):
                    lease.open()
        self.assertEqual(self.backend_calls, [])
        self.assertEqual(self.factory_calls, [])
        self.assertEqual(self.backend.events, [])

    def test_inventory_exception_is_preserved_without_open_or_retry(self):
        lease = self.lease(inventory_check=lambda: (_ for _ in ()).throw(OSError("inventory failure")))
        with self.assertRaisesRegex(OSError, "inventory failure"):
            lease.open()
        with self.assertRaises(RuntimeError):
            lease.open()
        self.assertEqual(self.backend_calls, [])

    def test_late_inventory_drift_closes_every_already_held_scope(self):
        calls = []
        def inventory():
            calls.append(len(self.backend.closed))
            return len(calls) == 1
        lease = self.lease(inventory_check=inventory)
        with self.assertRaisesRegex(ValueError, "inventory checkpoint"):
            lease.open()
        self.assertEqual(calls, [0, 0])
        self.assertEqual(len(self.factory_calls), 2)
        self.assert_released()
        with self.assertRaises(RuntimeError):
            _ = lease.digests

    def test_explicit_inventory_checkpoint_succeeds_without_reopening_handles(self):
        with self.lease() as lease:
            events = list(self.backend.events)
            self.assertIs(lease.verify_inventory(), True)
            self.assertEqual(self.backend.events, events)
            self.assertEqual(self.inventory_calls, [0, 513, 513])

    def test_failed_explicit_checkpoint_closes_and_cannot_be_reopened(self):
        lease = self.lease().open()
        lease._inventory_check = lambda: False
        with self.assertRaises(ValueError):
            lease.verify_inventory()
        self.assert_released()
        for action in (lease.open, lease.verify_inventory):
            with self.assertRaises(RuntimeError):
                action()

    def test_second_scope_factory_failure_closes_first_and_does_not_retry(self):
        calls = []
        def factory(*args, **options):
            calls.append(True)
            if len(calls) == 2:
                raise OSError("second constructor failed")
            return self.factory(*args, **options)
        lease = self.lease(protector_factory=factory)
        with self.assertRaisesRegex(OSError, "second constructor"):
            lease.open()
        self.assert_released()
        with self.assertRaises(RuntimeError):
            lease.open()

    def test_partial_second_scope_open_failure_closes_current_and_all_prior_handles(self):
        last = list(self.manifest)[-1]
        self.manifest[last] = "0" * 64
        lease = self.lease()
        with self.assertRaisesRegex(ValueError, "SHA256"):
            lease.open()
        self.assertEqual(len(self.factory_calls), 2)
        self.assert_released()
        self.assertEqual(len(self.inventory_calls), 1)

    def test_cross_scope_hardlink_identity_is_refused_and_unreturned_handle_is_closed(self):
        first, last = list(self.manifest)[0], list(self.manifest)[-1]
        self.backend.identities[last] = self.backend.identities[first]
        with self.assertRaisesRegex(ValueError, "across coverage"):
            self.lease().open()
        self.assertEqual(len(self.factory_calls), 2)
        self.assert_released()

    def test_cross_scope_global_byte_budget_applies_even_when_batches_fit(self):
        # Keep this deterministic and small while exercising the exact global
        # accounting path. Production limits are asserted separately above.
        paths = list(self.manifest)
        self.backend.files = {path: b"" for path in paths}
        self.backend.files[paths[0]] = b"four"
        self.backend.files[paths[-1]] = b"one"
        self.manifest = {path: hashlib.sha256(data).hexdigest()
                         for path, data in self.backend.files.items()}
        with patch.object(self.module, "MAX_FILE_BYTES", 4), patch.object(self.module, "MAX_TOTAL_BYTES", 6):
            with self.assertRaisesRegex(ValueError, "cumulative byte budget"):
                self.lease().open()
        self.assertEqual(len(self.factory_calls), 2)
        self.assert_released()

    def test_per_file_over_budget_refuses_before_read_and_closes(self):
        self.backend.size = lambda _handle: self.module.MAX_FILE_BYTES + 1
        self.backend.chunks = lambda *_args: (_ for _ in ()).throw(AssertionError("oversized file was read"))
        with self.assertRaisesRegex(ValueError, "per-file byte budget"):
            self.lease().open()
        self.assert_released()

    def test_size_must_be_a_nonnegative_integer_and_boolean_is_not_size_evidence(self):
        for size in (-1, True, 1.5):
            with self.subTest(size=size):
                self.backend = FileBackend(1)
                self.manifest = {next(iter(self.backend.files)): DIGEST}
                self.backend.size = lambda _handle, value=size: value
                with self.assertRaises(ValueError):
                    self.lease().open()
                self.assert_released()

    def test_changed_size_and_short_or_growing_reads_are_rejected_and_closed(self):
        for image in (b"on", b"ones"):
            with self.subTest(image=image):
                self.backend = FileBackend(1)
                self.manifest = {next(iter(self.backend.files)): DIGEST}
                self.backend.chunks = lambda *_args, data=image: iter((data,))
                with self.assertRaises(ValueError):
                    self.lease().open()
                self.assert_released()
        self.backend = FileBackend(1)
        self.manifest = {next(iter(self.backend.files)): DIGEST}
        sizes = iter((3, 4))
        self.backend.size = lambda _handle: next(sizes)
        with self.assertRaisesRegex(ValueError, "size changed"):
            self.lease().open()
        self.assert_released()

    def test_existing_runtime_output_refuses_without_a_claim_or_process_side_effect(self):
        self.backend.existing.add(r"C:\evidence\run\runner-claim.json")
        with patch.object(subprocess, "Popen", side_effect=AssertionError("process created")):
            with self.assertRaises(FileExistsError):
                self.lease().open()
        self.assert_released()

    def test_held_read_routes_to_both_original_scopes_without_reopen_and_requires_budget(self):
        first, last = list(self.manifest)[0], list(self.manifest)[-1]
        with self.lease() as lease:
            events = list(self.backend.events)
            for path in (first, last):
                self.assertEqual(lease.read_bytes(path.lower(), max_bytes=3), b"one")
            self.assertEqual(self.backend.events, events)
            with self.assertRaises(TypeError):
                lease.read_bytes(first)
            for budget in (0, True, 2, self.module.MAX_FILE_BYTES + 1):
                with self.subTest(budget=budget), self.assertRaises(ValueError):
                    lease.read_bytes(first, max_bytes=budget)
            with self.assertRaises(ValueError):
                lease.read_bytes(r"C:\outside.py", max_bytes=16)

    def test_repeated_held_reads_do_not_spend_the_verification_budget_twice(self):
        self.backend = FileBackend(1)
        self.manifest = {next(iter(self.backend.files)): DIGEST}
        with patch.object(self.module, "MAX_FILE_BYTES", 3), patch.object(self.module, "MAX_TOTAL_BYTES", 3):
            with self.lease() as lease:
                for _ in range(4):
                    self.assertEqual(lease.read_bytes(next(iter(self.manifest)), max_bytes=3), b"one")

    def test_closed_and_never_opened_reads_digests_and_checkpoints_refuse(self):
        lease = self.lease()
        for action in (lambda: lease.digests, lease.verify_inventory,
                       lambda: lease.read_bytes(next(iter(self.manifest)), max_bytes=3)):
            with self.assertRaises(RuntimeError):
                action()
        lease.close()
        lease.close()
        for action in (lease.open, lambda: lease.digests,
                       lambda: lease.read_bytes(next(iter(self.manifest)), max_bytes=3)):
            with self.assertRaises(RuntimeError):
                action()

    def test_context_nesting_refused_and_caller_exception_releases_everything(self):
        lease = self.lease().open()
        with self.assertRaisesRegex(RuntimeError, "caller failure"):
            with lease:
                with self.assertRaises(RuntimeError):
                    lease.__enter__()
                raise RuntimeError("caller failure")
        self.assert_released()

    def test_no_claim_launch_or_process_ownership_api_is_exposed(self):
        lease = self.lease()
        for name in ("claim_attempt", "launch", "create_process", "request_stop", "terminate", "pid"):
            self.assertFalse(hasattr(lease, name))


@unittest.skipUnless(os.name == "nt", "actual Win32 file sharing requires Windows")
class WindowsCoverageLeaseContracts(unittest.TestCase):
    def setUp(self):
        self.module = load_source("input_coverage_lease")
        self.old = load_source("protected_inputs")
        self.temporary = tempfile.TemporaryDirectory(prefix="beamrt-bulk-coverage-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.inputs, self.run = self.directory / "inputs", self.directory / "run"
        self.inputs.mkdir()
        self.run.mkdir()
        self.paths = [self.inputs / f"fixture-{index:04d}.txt" for index in range(513)]
        self.manifest = {}
        for index, path in enumerate(self.paths):
            image = f"bulk held fixture {index}\n".encode("ascii")
            path.write_bytes(image)
            self.manifest[str(path)] = hashlib.sha256(image).hexdigest()

    def lease(self, **options):
        options.setdefault("inventory_check", lambda: True)
        return self.module.CoverageLease(self.manifest, self.run,
                                         protector_factory=self.old.ProtectedInputs,
                                         backend_factory=self.old._Win32, **options)

    def test_actual_513_files_hold_first_and_last_inputs_and_directories_until_explicit_close(self):
        first, last = self.paths[0], self.paths[-1]
        with self.lease() as lease:
            self.assertEqual(len(lease.digests), 513)
            for path in (first, last):
                self.assertEqual(lease.read_bytes(path, max_bytes=128), path.read_bytes())
                with self.assertRaises(OSError):
                    path.write_bytes(b"must stay frozen")
                with self.assertRaises(OSError):
                    path.unlink()
            for directory in (self.inputs, self.run):
                with self.assertRaises(OSError):
                    directory.rename(self.directory / (directory.name + "-moved"))
            # The directory lease is not a sealed namespace or a write ban.
            (self.inputs / "new-name-is-not-sealed.txt").write_bytes(b"permitted")
        first.write_bytes(b"first released")
        last.write_bytes(b"last released")

    def test_actual_cross_scope_hardlink_alias_is_refused_and_prior_handles_release(self):
        alias = self.paths[-1]
        alias.unlink()
        os.link(self.paths[0], alias)
        self.manifest[str(alias)] = self.manifest[str(self.paths[0])]
        with self.assertRaisesRegex(ValueError, "across coverage"):
            self.lease().open()
        self.paths[0].write_bytes(b"released after hardlink refusal")
        self.assertFalse((self.run / "runner-claim.json").exists())

    def test_actual_late_inventory_change_refuses_and_releases_all_scopes(self):
        calls = []
        def inventory():
            calls.append(True)
            if len(calls) == 2:
                (self.inputs / "late-input.txt").write_bytes(b"observed namespace drift")
            return len(list(self.inputs.iterdir())) == len(self.manifest)
        with self.assertRaisesRegex(ValueError, "inventory checkpoint"):
            self.lease(inventory_check=inventory).open()
        self.assertEqual(len(calls), 2)
        self.paths[0].write_bytes(b"first released after inventory refusal")
        self.paths[-1].write_bytes(b"last released after inventory refusal")

    def test_actual_changed_input_refuses_and_releases_previous_scope(self):
        self.paths[-1].write_bytes(b"changed before acquisition")
        with self.assertRaisesRegex(ValueError, "SHA256"):
            self.lease().open()
        self.paths[0].write_bytes(b"first released after hash refusal")
        self.assertFalse((self.run / "runner-claim.json").exists())

    def test_actual_missing_input_refuses_and_releases_previous_scope(self):
        self.paths[-1].unlink()
        with self.assertRaises(OSError):
            self.lease().open()
        self.paths[0].write_bytes(b"first released after absent-input refusal")
        self.assertFalse((self.run / "runner-claim.json").exists())


if __name__ == "__main__":
    unittest.main()
